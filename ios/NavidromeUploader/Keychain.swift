//
//  Keychain.swift
//  Navidrome Uploader
//
//  Minimal Keychain wrapper for storing the upload token securely.
//  Uses kSecClassGenericPassword keyed by a service + account string.
//  Copied from the Viu Live TV pattern.
//

import Foundation
import Security

struct Keychain {
    static let shared = Keychain()

    private let service = "com.c12n.navidromeuploader.token"

    // MARK: Generic string storage

    @discardableResult
    func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Delete any existing item first, then add fresh.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Convenience for the upload token

    private let tokenAccount = "upload_token"

    var uploadToken: String? {
        get { get(account: tokenAccount) }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                set(newValue, account: tokenAccount)
            } else {
                delete(account: tokenAccount)
            }
        }
    }
}
