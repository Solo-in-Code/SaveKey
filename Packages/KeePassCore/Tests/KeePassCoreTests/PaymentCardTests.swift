// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import KeePassCore

final class PaymentCardTests: XCTestCase {
    typealias Line = CardTextParser.Line

    func testBrandDetection() {
        let cases: [(String, CardBrand)] = [
            ("4111 1111 1111 1111", .visa),
            ("5555555555554444", .mastercard),
            ("2223003122003222", .mastercard),
            ("378282246310005", .amex),
            ("6011111111111117", .discover),
            ("30569309025904", .diners),
            ("3530111333300000", .jcb),
            ("6200000000000005", .unionPay),
            ("6759649826438453", .maestro),
            ("6362970000457013", .elo),
            ("5067 0000 0000 0000", .elo),
            ("6062828888666688", .hipercard),
            ("2200123412341234", .mir),
            ("4", .visa),
            ("37", .amex),
        ]
        for (number, brand) in cases {
            XCTAssertEqual(CardBrand.detect(number), brand, number)
        }
        XCTAssertNil(CardBrand.detect("9999 9999"))
        XCTAssertNil(CardBrand.detect(""))
    }

    func testLuhnAndFormatting() {
        XCTAssertTrue(Luhn.isValid("4111 1111 1111 1111"))
        XCTAssertTrue(Luhn.isValid("378282246310005"))
        XCTAssertFalse(Luhn.isValid("4111 1111 1111 1112"))
        XCTAssertFalse(Luhn.isValid("1234"))
        XCTAssertEqual(PaymentCard.format("4111111111111111"), "4111 1111 1111 1111")
        XCTAssertEqual(PaymentCard.format("378282246310005"), "3782 822463 10005")
        XCTAssertEqual(PaymentCard.format("30569309025904"), "3056 930902 5904")
        XCTAssertEqual(PaymentCard.format("411111"), "4111 11")
        XCTAssertEqual(PaymentCard.format("4111-1111 abc"), "4111 1111")
        XCTAssertEqual(PaymentCard.format("4000000000000000006"), "4000 0000 0000 0000 006")
    }

    func testExpiry() {
        XCTAssertEqual(CardExpiry(string: "12/27"), CardExpiry(month: 12, year: 2027))
        XCTAssertEqual(CardExpiry(string: "3/2029"), CardExpiry(month: 3, year: 2029))
        XCTAssertEqual(CardExpiry(string: "07-26"), CardExpiry(month: 7, year: 2026))
        XCTAssertEqual(CardExpiry(string: "0828"), CardExpiry(month: 8, year: 2028))
        XCTAssertEqual(CardExpiry(string: "2030-05-31"), CardExpiry(month: 5, year: 2030))
        XCTAssertNil(CardExpiry(string: "13/27"))
        XCTAssertNil(CardExpiry(string: "hello"))
        let e = CardExpiry(month: 2, year: 2028)!
        XCTAssertEqual(e.shortString, "02/28")
        XCTAssertEqual(CardExpiry(date: e.keepassDate), e, "the stored KeePass date must map back to the same month")
        XCTAssertFalse(e.isExpired(at: CardExpiry(month: 2, year: 2028)!.keepassDate))
        XCTAssertTrue(CardExpiry(month: 1, year: 2020)!.isExpired())
        XCTAssertGreaterThan(CardExpiry(month: 1, year: 2028)!, CardExpiry(month: 12, year: 2027)!)
    }

    func testEntryRoundTripUsesKeePassDXFields() {
        let entry = KPEntry()
        var card = PaymentCard()
        card.holder = "JOÃO S GOMES"
        card.number = "4111111111111111"
        card.expiry = CardExpiry(month: 12, year: 2027)
        card.cvv = "123"
        card.apply(to: entry)

        XCTAssertEqual(entry.field("Number")?.value, "4111111111111111")
        XCTAssertEqual(entry.field("Number")?.isProtected, true)
        XCTAssertEqual(entry.field("CVV")?.isProtected, true)
        XCTAssertEqual(entry.field("Holder")?.value, "JOÃO S GOMES")
        XCTAssertEqual(entry.field("Brand")?.value, "Visa")
        XCTAssertNil(entry.field("PIN"), "PIN is only written when set")
        XCTAssertTrue(entry.times.expires)

        let read = PaymentCard.from(entry: entry)
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.number, card.number)
        XCTAssertEqual(read?.holder, card.holder)
        XCTAssertEqual(read?.expiry, card.expiry)
        XCTAssertEqual(read?.cvv, "123")
        XCTAssertEqual(read?.resolvedBrand, .visa)
        XCTAssertEqual(read?.maskedNumber, "•••• 1111")
        XCTAssertEqual(read?.defaultTitle, "Visa •••• 1111")
    }

    func testReadsKeePassDXAndOtherCardEntries() {
        // KeePassDX "Debit / Credit Card" template: Number, Holder, CVV, PIN + entry expiry date.
        let dx = KPEntry()
        dx.setValue("5555 5555 5555 4444", for: "Number")
        dx.setValue("MARIA SILVA", for: "Holder")
        dx.setValue("321", for: "CVV", protected: true)
        dx.setValue("4321", for: "PIN", protected: true)
        dx.times.expires = true
        dx.times.expiry = CardExpiry(month: 3, year: 2028)!.keepassDate
        let card = PaymentCard.from(entry: dx)
        XCTAssertEqual(card?.number, "5555555555554444")
        XCTAssertEqual(card?.resolvedBrand, .mastercard)
        XCTAssertEqual(card?.pin, "4321")
        XCTAssertEqual(card?.expiry, CardExpiry(month: 3, year: 2028))

        // Other naming styles are read and written back to the same field names.
        let other = KPEntry()
        other.setValue("378282246310005", for: "Card Number")
        other.setValue("11/26", for: "Expiry")
        var amex = PaymentCard.from(entry: other)!
        XCTAssertEqual(amex.expiry, CardExpiry(month: 11, year: 2026))
        amex.cvv = "1234"
        amex.expiry = CardExpiry(month: 1, year: 2030)
        amex.apply(to: other)
        XCTAssertEqual(other.field("Card Number")?.value, "378282246310005")
        XCTAssertNil(other.field("Number"))
        XCTAssertEqual(other.field("Expiry")?.value, "01/30")
        XCTAssertEqual(other.field("CVV")?.value, "1234")

        // Not cards.
        let plain = KPEntry()
        plain.setValue("123456789012", for: "Number")
        XCTAssertNil(PaymentCard.from(entry: plain), "a bare Number field is not a card")
        let login = KPEntry()
        login.title = "Email"
        login.password = "4111111111111111"
        XCTAssertNil(PaymentCard.from(entry: login))
    }

    func testCardSurvivesSaveAndReopen() throws {
        let db = Database.create(name: "Cards", settings: DatabaseSettings(kdf: .aes(rounds: 10, seed: SecureRandom.bytes(32))))
        let banking = db.root.groups.first { $0.name == "Banking" }!
        let entry = db.createEntry(in: banking)
        entry.title = "My Visa"
        var card = PaymentCard()
        card.number = "4111111111111111"
        card.holder = "ANA LIMA"
        card.expiry = CardExpiry(month: 9, year: 2029)
        card.cvv = "987"
        card.pin = "1357"
        card.apply(to: entry)
        entry.attachments.append(Attachment(name: PaymentCard.frontImageName, data: Data([0xFF, 0xD8, 0xFF])))
        let key = try CompositeKey(password: "pw", keyFileData: nil)
        let reopened = try KDBX.open(try KDBX.save(db, key: key), key: key)
        let back = PaymentCard.from(entry: reopened.entry(uuid: entry.uuid)!)
        XCTAssertEqual(back?.number, "4111111111111111")
        XCTAssertEqual(back?.holder, "ANA LIMA")
        XCTAssertEqual(back?.expiry, CardExpiry(month: 9, year: 2029))
        XCTAssertEqual(back?.cvv, "987")
        XCTAssertEqual(back?.pin, "1357")
        XCTAssertEqual(reopened.entry(uuid: entry.uuid)?.attachments.first?.name, "Card front.jpg")
    }

    // MARK: OCR parsing

    func testParsesVisaFrontAndBack() {
        let front = [
            Line(text: "BANCO EXEMPLO", x: 0.06, y: 0.08, width: 0.4, height: 0.06),
            Line(text: "4111 1111", x: 0.08, y: 0.52, width: 0.35, height: 0.08),
            Line(text: "1111 1111", x: 0.45, y: 0.525, width: 0.35, height: 0.08),
            Line(text: "VALID", x: 0.40, y: 0.66, width: 0.08, height: 0.03),
            Line(text: "THRU", x: 0.40, y: 0.69, width: 0.08, height: 0.03),
            Line(text: "12/27", x: 0.50, y: 0.665, width: 0.12, height: 0.05),
            Line(text: "JOAO S GOMES", x: 0.08, y: 0.80, width: 0.4, height: 0.05),
            Line(text: "VISA", x: 0.78, y: 0.82, width: 0.15, height: 0.07),
        ]
        let back = [
            Line(text: "AUTHORIZED SIGNATURE", x: 0.05, y: 0.30, width: 0.4, height: 0.03),
            Line(text: "1111 123", x: 0.55, y: 0.40, width: 0.25, height: 0.05),
            Line(text: "Customer service 0800 123 4567", x: 0.05, y: 0.85, width: 0.7, height: 0.04),
        ]
        let r = CardTextParser.parse(front: front, back: back)
        XCTAssertEqual(r.number, "4111111111111111")
        XCTAssertEqual(r.brand, .visa)
        XCTAssertEqual(r.expiry, CardExpiry(month: 12, year: 2027))
        XCTAssertEqual(r.holder, "JOAO S GOMES")
        XCTAssertEqual(r.cvv, "123")
    }

    func testParsesNoisyOCR() {
        let front = [
            Line(text: "MILLENNIUM", x: 0.05, y: 0.05, width: 0.3, height: 0.06),
            Line(text: "Debit", x: 0.7, y: 0.05, width: 0.2, height: 0.06),
            Line(text: "4III 1111 1111 11I1", x: 0.08, y: 0.50, width: 0.8, height: 0.08),
            Line(text: "VALID FROM 01/22 VALID THRU 12/27", x: 0.2, y: 0.64, width: 0.7, height: 0.04),
            Line(text: "Maria J Santos", x: 0.08, y: 0.80, width: 0.4, height: 0.05),
        ]
        let r = CardTextParser.parse(front: front)
        XCTAssertEqual(r.number, "4111111111111111")
        XCTAssertEqual(r.expiry, CardExpiry(month: 12, year: 2027), "the later date is the expiry")
        XCTAssertEqual(r.holder, "Maria J Santos")
        XCTAssertNil(r.cvv, "no back side scanned")
    }

    func testParsesAmexWithFrontSecurityCode() {
        let front = [
            Line(text: "AMERICAN EXPRESS", x: 0.05, y: 0.06, width: 0.5, height: 0.06),
            Line(text: "1234", x: 0.78, y: 0.38, width: 0.12, height: 0.04),
            Line(text: "3782 822463 10005", x: 0.08, y: 0.50, width: 0.8, height: 0.08),
            Line(text: "MEMBER SINCE 15", x: 0.08, y: 0.64, width: 0.3, height: 0.03),
            Line(text: "VALID THRU 01/29", x: 0.5, y: 0.64, width: 0.3, height: 0.03),
            Line(text: "JANE DOE", x: 0.08, y: 0.78, width: 0.3, height: 0.05),
        ]
        let r = CardTextParser.parse(front: front)
        XCTAssertEqual(r.number, "378282246310005")
        XCTAssertEqual(r.brand, .amex)
        XCTAssertEqual(r.cvv, "1234")
        XCTAssertEqual(r.holder, "JANE DOE")
        XCTAssertEqual(r.expiry, CardExpiry(month: 1, year: 2029))
    }

    func testNothingFoundOnUnrelatedText() {
        let r = CardTextParser.parse(front: [Line(text: "Hello world 2024"), Line(text: "Call 0800 123 456")])
        XCTAssertNil(r.number)
        XCTAssertNil(r.expiry)
        XCTAssertFalse(r.foundAnything && r.number != nil)
    }
}
