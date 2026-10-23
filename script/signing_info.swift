// MIT License. Read-only, structured signing inspection; never launches code.
import Foundation
import Security

func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: "OpenCoveSigning", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(status))."])
    }
}

do {
    guard CommandLine.arguments.count >= 3 else {
        throw NSError(domain: "OpenCoveSigning", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: signing_info.swift APP ARCH [ARCH]"])
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    // Apple TN3127: the Apple anchor and certificate extensions establish the
    // certificate class. The name printed by codesign cannot do so.
    let developerIDExpression = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists " +
        "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    var developerIDRequirement: SecRequirement?
    try checked(SecRequirementCreateWithString(developerIDExpression as CFString, [], &developerIDRequirement), "Create Developer ID requirement")
    var slices: [[String: Any]] = []
    for architecture in CommandLine.arguments.dropFirst(2) {
        var result: SecStaticCode?
        let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
        try checked(SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &result), "Open static code")
        guard let code = result else { throw NSError(domain: "OpenCoveSigning", code: 2) }
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        try checked(SecStaticCodeCheckValidity(code, validationFlags, nil), "Validate signature")
        var raw: CFDictionary?
        try checked(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw), "Read signing information")
        guard let info = raw as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? NSNumber else {
            throw NSError(domain: "OpenCoveSigning", code: 3)
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        var developerID = false
        if SecStaticCodeCheckValidity(code, validationFlags, developerIDRequirement) == errSecSuccess,
           let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            let expression = developerIDExpression + " and certificate leaf[subject.OU] = \"\(team)\""
            var requirement: SecRequirement?
            try checked(SecRequirementCreateWithString(expression as CFString, [], &requirement), "Create Developer ID requirement")
            developerID = SecStaticCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess
        }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let automation = entitlements["com.apple.security.automation.apple-events"] as? NSNumber
        let exactEntitlement = entitlements.count == 1 && automation.map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } == true
        // The only upstream helper that can need entitlements is Downloader.
        // Never accept debugging or disabled library-validation entitlements.
        let downloaderKeys: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.network.client"]
        let safeSparkleEntitlements = entitlements.isEmpty ||
            (url.lastPathComponent == "Downloader.xpc" && Set(entitlements.keys).isSubset(of: downloaderKeys) &&
             entitlements.values.allSatisfy { value in
                 guard let boolean = value as? NSNumber else { return false }
                 return CFGetTypeID(boolean) == CFBooleanGetTypeID() && boolean.boolValue
             })
        let timestamp = (info[kSecCodeInfoTimestamp as String] as? Date).map { ISO8601DateFormatter().string(from: $0) }
        slices.append([
            "architecture": architecture,
            "adHoc": flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0,
            "runtime": flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
            "developerIDApplication": developerID,
            "teamIdentifier": team as Any? ?? NSNull(),
            "secureTimestamp": timestamp as Any? ?? NSNull(),
            "automationEntitlementOnly": exactEntitlement,
            "safeSparkleEntitlements": safeSparkleEntitlements,
        ])
    }
    let data = try JSONSerialization.data(withJSONObject: slices, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("OpenCove signing: \(error.localizedDescription)\n".utf8))
    exit(1)
}
