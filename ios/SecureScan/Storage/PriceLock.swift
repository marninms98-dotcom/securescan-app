//
//  PriceLock.swift
//  SecureScan
//
//  "Show prices" (off by default): the crew scopes without seeing money.
//  Turning it on asks for the office PIN, which the owner sets the first time.
//  The PIN is kept in the Keychain. This is a convenience lock to keep prices
//  off the crew's screens, not security: anyone with the phone's passcode and
//  some determination can get round it.
//

import Foundation
import Security

extension Notification.Name {
    static let pricesVisibleChanged = Notification.Name("SecureScan.pricesVisibleChanged")
}

enum PriceLock {
    private static let key = "showPrices"
    private static let service = "com.secureworkswa.securescan.officepin"

    static var pricesVisible: Bool {
        get {
            #if DEBUG
            // Simulator / CI only (Debug builds): SECURESCAN_PRICES=1 shows prices without the PIN.
            if let v = ProcessInfo.processInfo.environment["SECURESCAN_PRICES"] { return v == "1" }
            #endif
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .pricesVisibleChanged, object: nil)
        }
    }

    /// 4 to 8 digits.
    static func validPIN(_ pin: String) -> Bool { PinRule.valid(pin) }

    static var hasPIN: Bool { readPIN() != nil }

    static func check(_ pin: String) -> Bool { readPIN().map { $0 == pin } ?? false }

    @discardableResult
    static func setPIN(_ pin: String) -> Bool {
        guard validPIN(pin), let data = pin.data(using: .utf8) else { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func readPIN() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
