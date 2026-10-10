// Native Keychain bridge. Secrets travel only through private stdin/stdout pipes.
import Foundation
import Security

func fail(_ status: OSStatus) -> Never {
    // No Keychain metadata or password is included in error output.
    FileHandle.standardError.write(Data("Keychain operation unavailable\n".utf8))
    exit(status == errSecItemNotFound ? 3 : 4)
}

let arguments = CommandLine.arguments
guard arguments.count == 4,
      ["get", "put", "delete"].contains(arguments[1]),
      !arguments[2].isEmpty, !arguments[3].isEmpty else {
    exit(2)
}
let operation = arguments[1]
// Background reads must never show an access/unlock dialog.
SecKeychainSetUserInteractionAllowed(operation != "get")
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: arguments[2],
    kSecAttrAccount as String: arguments[3],
    kSecAttrSynchronizable as String: false
]

switch operation {
case "get":
    var readQuery = query
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
    guard status == errSecSuccess else { fail(status) }
    guard let password = result as? Data, !password.isEmpty else { exit(4) }
    FileHandle.standardOutput.write(password)
case "put":
    // The caller closes its pipe after sending the passphrase, not a shell command.
    let password = FileHandle.standardInput.readDataToEndOfFile()
    guard !password.isEmpty, password.count <= 16384,
          String(data: password, encoding: .utf8) != nil else { exit(2) }
    let attributes: [String: Any] = [kSecValueData as String: password]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = password
        item[kSecAttrLabel as String] = "Org Calendar token-store passphrase"
        // Default Keychain access trusts this native helper, not all applications.
        status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { fail(status) }
    FileHandle.standardOutput.write(Data("OK\n".utf8))
default:
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail(status) }
    FileHandle.standardOutput.write(Data("OK\n".utf8))
}
