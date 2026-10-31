import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    // MARK: - Claude Code OAuth token (written by Claude Code CLI)

    private let claudeCredentialsService = "Claude Code-credentials"

    /// Claude Code writes its credentials with /usr/bin/security, which leaves that tool on the
    /// item's access list. Reading through it avoids a Keychain prompt; reading directly would
    /// prompt whenever ClaudeBar's ad-hoc signature changes, since macOS only trusts the exact
    /// build that was last allowed.
    func readClaudeOAuthToken() async -> String? {
        let data: Data?
        if let viaTool = await readViaSecurityTool(service: claudeCredentialsService) {
            data = viaTool
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: claudeCredentialsService,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            data = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }

        // expiresAt is stored as milliseconds since epoch by the Claude Code CLI
        if let expiresAt = oauth["expiresAt"] as? Double {
            let seconds = expiresAt > 1e10 ? expiresAt / 1000 : expiresAt
            if Date(timeIntervalSince1970: seconds) < Date() { return nil }
        }

        return token
    }

    private func readViaSecurityTool(service: String) async -> Data? {
        await withCheckedContinuation { cont in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: p.terminationStatus == 0 && !data.isEmpty ? data : nil)
            }
            do { try process.run() } catch { cont.resume(returning: nil) }
        }
    }

    // MARK: - Admin API key (stored by ClaudeBar)

    private let adminKeyService = "com.wtjohns.ClaudeBar.admin-key"

    func readAdminKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: adminKeyService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func saveAdminKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: adminKeyService
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func deleteAdminKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: adminKeyService
        ]
        SecItemDelete(query as CFDictionary)
    }
}
