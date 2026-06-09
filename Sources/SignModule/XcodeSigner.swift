import Foundation

/// Engine ký + cài app iOS bằng toolchain native của macOS (Xcode + codesign + devicectl).
/// Công thức đã kiểm chứng trên iOS 18.7.1 + Intel Mac (xem memory ios-sideload-working-recipe).
public enum XcodeSigner {

    // MARK: - Process helper

    @discardableResult
    static func run(_ launch: String, _ args: [String],
                    log: ((String) -> Void)? = nil) throws -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        var data = Data()
        // đọc dần để không nghẽn pipe với output lớn (xcodebuild)
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if let s = String(data: chunk, encoding: .utf8) { log?(s) }
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func which(_ tool: String) -> String? {
        // ưu tiên các đường chuẩn; fallback /usr/bin/env
        let candidates = ["/usr/bin/\(tool)", "/usr/local/bin/\(tool)", "/opt/homebrew/bin/\(tool)"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        if let r = try? run("/usr/bin/which", [tool]), r.code == 0 {
            let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return nil
    }

    // MARK: - Signing identities & teams

    /// Liệt kê các signing identity "Apple Development" trong Keychain → (sha1, name).
    public static func listSigningIdentities() throws -> [(sha1: String, name: String)] {
        let r = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        var out: [(String, String)] = []
        // dòng dạng:  1) <SHA1> "Apple Development: email (XXXX)"
        let re = try NSRegularExpression(pattern: #"\)\s+([0-9A-F]{40})\s+\"(.+)\""#)
        for line in r.out.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if let m = re.firstMatch(in: s, range: range),
               let shaR = Range(m.range(at: 1), in: s),
               let nameR = Range(m.range(at: 2), in: s) {
                let name = String(s[nameR])
                if name.contains("Apple Development") {
                    out.append((String(s[shaR]), name))
                }
            }
        }
        return out
    }

    /// Lấy Team ID (trường OU của subject) từ cert theo tên.
    public static func teamID(forCertNamed name: String) throws -> String {
        let pem = try run("/usr/bin/security", ["find-certificate", "-c", name, "-p"])
        guard pem.code == 0, !pem.out.isEmpty else {
            throw SignError("Không tìm thấy cert: \(name)")
        }
        // openssl x509 -noout -subject
        let tmp = NSTemporaryDirectory() + "cert-\(UUID().uuidString).pem"
        try pem.out.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let openssl = which("openssl") ?? "/usr/bin/openssl"
        let subj = try run(openssl, ["x509", "-noout", "-subject", "-in", tmp])
        // subject= ... OU = S65V477X4H, ...   (định dạng có thể "OU=" hoặc "OU = ")
        if let m = try NSRegularExpression(pattern: #"OU\s*=\s*([A-Z0-9]{10})"#)
            .firstMatch(in: subj.out, range: NSRange(subj.out.startIndex..., in: subj.out)),
           let r = Range(m.range(at: 1), in: subj.out) {
            return String(subj.out[r])
        }
        throw SignError("Không đọc được Team ID (OU) từ cert: \(name)")
    }

    // MARK: - Devices

    /// Liệt kê thiết bị iOS đang kết nối (USB) → (udid, name).
    public static func listConnectedDevices() -> [(udid: String, name: String)] {
        guard let ideviceID = which("idevice_id") else { return [] }
        guard let r = try? run(ideviceID, ["-l"]), r.code == 0 else { return [] }
        var devices: [(String, String)] = []
        for udid in r.out.split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init) where !udid.isEmpty {
            var name = udid
            if let info = which("ideviceinfo"),
               let nr = try? run(info, ["-u", udid, "-k", "DeviceName"]), nr.code == 0 {
                let n = nr.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { name = n }
            }
            devices.append((udid, name))
        }
        return devices
    }

    // MARK: - Stub project (để Xcode sinh provisioning profile)

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacUtil/SignStub", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Tạo stub Xcode project (1 lần) — bundle id & team override qua command-line khi build.
    static func ensureStubProject() throws -> URL {
        let proj = supportDir.appendingPathComponent("Stub.xcodeproj")
        let pbxproj = proj.appendingPathComponent("project.pbxproj")
        let swiftFile = supportDir.appendingPathComponent("StubApp.swift")
        if !FileManager.default.fileExists(atPath: pbxproj.path) {
            try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
            try Self.stubPbxproj.write(to: pbxproj, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: swiftFile.path) {
            try Self.stubSwift.write(to: swiftFile, atomically: true, encoding: .utf8)
        }
        return proj
    }

    // MARK: - Bước 1: sinh provisioning profile cho (team, bundleID, device)

    /// Trả về (đường dẫn .mobileprovision, entitlements plist data).
    public static func generateProfile(teamID: String, bundleID: String, udid: String,
                                       log: @escaping (String) -> Void) throws -> URL {
        let proj = try ensureStubProject()
        log("→ Sinh provisioning profile cho \(bundleID) (team \(teamID))...\n")
        let xcodebuild = "/usr/bin/xcodebuild"
        let r = try run(xcodebuild, [
            "-project", proj.path,
            "-scheme", "Stub",
            "-destination", "platform=iOS,id=\(udid)",
            "-allowProvisioningUpdates",
            "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
            "DEVELOPMENT_TEAM=\(teamID)",
            "build"
        ], log: log)
        guard r.code == 0 else {
            throw SignError("xcodebuild tạo profile thất bại (xem log). Account đã đăng nhập Xcode chưa?")
        }
        // tìm profile có application-identifier == teamID.bundleID
        let appID = "\(teamID).\(bundleID)"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "mobileprovision" } ?? []
        var best: (URL, Date)?
        for f in files {
            guard let ent = try? entitlements(ofProfile: f),
                  ent["application-identifier"] as? String == appID else { continue }
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || mod > best!.1 { best = (f, mod) }
        }
        guard let profile = best?.0 else {
            throw SignError("Không tìm thấy profile cho \(appID) sau khi build.")
        }
        return profile
    }

    /// Đọc dict Entitlements từ 1 .mobileprovision.
    public static func entitlements(ofProfile profile: URL) throws -> [String: Any] {
        let r = try run("/usr/bin/security", ["cms", "-D", "-i", profile.path])
        guard let data = r.out.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any] else {
            throw SignError("Không đọc được entitlements từ profile.")
        }
        return ent
    }

    // MARK: - Bước 2: resign IPA

    /// Resign IPA với cert + profile + bundleID mới. Trả đường dẫn IPA đã ký.
    public static func resign(ipa: URL, certSHA1: String, profile: URL,
                              bundleID: String, log: @escaping (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let work = supportDir.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        log("→ Giải nén IPA...\n")
        let unzip = try run("/usr/bin/unzip", ["-q", ipa.path, "-d", work.path], log: nil)
        guard unzip.code == 0 else { throw SignError("Giải nén IPA thất bại.") }

        let payload = work.appendingPathComponent("Payload")
        guard let appName = (try? fm.contentsOfDirectory(atPath: payload.path))?
                .first(where: { $0.hasSuffix(".app") }) else {
            throw SignError("Không thấy .app trong Payload.")
        }
        let app = payload.appendingPathComponent(appName)

        // đổi CFBundleIdentifier
        log("→ Đổi bundle id → \(bundleID)\n")
        let infoPlist = app.appendingPathComponent("Info.plist")
        var info = try plistDict(at: infoPlist)
        info["CFBundleIdentifier"] = bundleID
        try writePlist(info, to: infoPlist)

        // nhúng profile
        try? fm.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
        try fm.copyItem(at: profile, to: app.appendingPathComponent("embedded.mobileprovision"))

        // entitlements
        let ent = try entitlements(ofProfile: profile)
        let entPath = work.appendingPathComponent("entitlements.plist")
        try writePlist(ent, to: entPath)

        // ký nested code trước (dylib/framework/appex), rồi app chính
        log("→ Ký...\n")
        if let enumr = fm.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let u as URL in enumr {
                let ext = u.pathExtension
                if ext == "dylib" || ext == "framework" || ext == "appex" {
                    _ = try run("/usr/bin/codesign", ["-f", "-s", certSHA1, "--generate-entitlement-der", u.path], log: log)
                }
            }
        }
        let signApp = try run("/usr/bin/codesign",
            ["-f", "-s", certSHA1, "--entitlements", entPath.path, "--generate-entitlement-der", app.path], log: log)
        guard signApp.code == 0 else { throw SignError("codesign thất bại (xem log).") }

        // đóng gói lại — ditto giữ thư mục Payload làm gốc của zip (cấu trúc IPA đúng)
        let signedIPA = supportDir.appendingPathComponent("signed-\(UUID().uuidString).ipa")
        try? fm.removeItem(at: signedIPA)
        let ditto = try run("/usr/bin/ditto",
            ["-c", "-k", "--keepParent", payload.path, signedIPA.path], log: nil)
        guard ditto.code == 0, fm.fileExists(atPath: signedIPA.path) else {
            throw SignError("Đóng gói IPA thất bại.")
        }
        return signedIPA
    }

    // MARK: - Bước 3: cài qua devicectl

    public static func install(ipa: URL, udid: String, log: @escaping (String) -> Void) throws {
        log("→ Cài lên thiết bị (devicectl)...\n")
        let r = try run("/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", udid, ipa.path], log: log)
        guard r.code == 0 else { throw SignError("devicectl cài thất bại (xem log).") }
    }

    // MARK: - Orchestration

    /// Bundle id duy nhất: com.<teamID>.<slug>  (id generic hay bị trùng → phải đổi).
    public static func uniqueBundleID(teamID: String, appName: String) -> String {
        let slug = String(String.UnicodeScalarView(
            appName.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        return "com.\(teamID).\(slug.isEmpty ? "app" : slug)"
    }

    /// Toàn bộ: profile → resign → install. Trả (signedBundleID).
    public static func signAndInstall(ipa: URL, team: SignTeam, appName: String, udid: String,
                                      log: @escaping (String) -> Void) throws -> String {
        let bundleID = uniqueBundleID(teamID: team.teamID, appName: appName)
        let profile = try generateProfile(teamID: team.teamID, bundleID: bundleID, udid: udid, log: log)
        let signed = try resign(ipa: ipa, certSHA1: team.certSHA1, profile: profile, bundleID: bundleID, log: log)
        defer { try? FileManager.default.removeItem(at: signed) }
        try install(ipa: signed, udid: udid, log: log)
        log("✓ Hoàn tất — \(bundleID)\n")
        return bundleID
    }

    // MARK: - plist helpers (xử lý cả binary plist)

    static func plistDict(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SignError("Không đọc được plist: \(url.lastPathComponent)")
        }
        return dict
    }

    static func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    // MARK: - Stub project template

    static let stubSwift = """
    import SwiftUI
    @main struct StubApp: App { var body: some Scene { WindowGroup { Text(\"stub\") } } }
    """

    static let stubPbxproj = #"""
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 56;
    	objects = {
    		AA0000000000000000000001 /* StubApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA0000000000000000000002 /* StubApp.swift */; };
    		AA0000000000000000000002 /* StubApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StubApp.swift; sourceTree = "<group>"; };
    		AA0000000000000000000003 /* Stub.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Stub.app; sourceTree = BUILT_PRODUCTS_DIR; };
    		AA0000000000000000000004 /* Frameworks */ = {
    			isa = PBXFrameworksBuildPhase;
    			buildActionMask = 2147483647;
    			files = (
    			);
    			runOnlyForDeploymentPostprocessing = 0;
    		};
    		AA0000000000000000000005 = {
    			isa = PBXGroup;
    			children = (
    				AA0000000000000000000002 /* StubApp.swift */,
    				AA0000000000000000000006 /* Products */,
    			);
    			sourceTree = "<group>";
    		};
    		AA0000000000000000000006 /* Products */ = {
    			isa = PBXGroup;
    			children = (
    				AA0000000000000000000003 /* Stub.app */,
    			);
    			name = Products;
    			sourceTree = "<group>";
    		};
    		AA0000000000000000000007 /* Stub */ = {
    			isa = PBXNativeTarget;
    			buildConfigurationList = AA0000000000000000000008 /* Build configuration list for PBXNativeTarget "Stub" */;
    			buildPhases = (
    				AA0000000000000000000009 /* Sources */,
    				AA0000000000000000000004 /* Frameworks */,
    				AA000000000000000000000A /* Resources */,
    			);
    			buildRules = (
    			);
    			dependencies = (
    			);
    			name = Stub;
    			productName = Stub;
    			productReference = AA0000000000000000000003 /* Stub.app */;
    			productType = "com.apple.product-type.application";
    		};
    		AA000000000000000000000B /* Project object */ = {
    			isa = PBXProject;
    			attributes = {
    				BuildIndependentTargetsInParallel = 1;
    				LastSwiftUpdateCheck = 1620;
    				LastUpgradeCheck = 1620;
    				TargetAttributes = {
    					AA0000000000000000000007 = {
    						CreatedOnToolsVersion = 16.2;
    					};
    				};
    			};
    			buildConfigurationList = AA000000000000000000000C /* Build configuration list for PBXProject "Stub" */;
    			compatibilityVersion = "Xcode 14.0";
    			developmentRegion = en;
    			hasScannedForEncodings = 0;
    			knownRegions = (
    				en,
    				Base,
    			);
    			mainGroup = AA0000000000000000000005;
    			productRefGroup = AA0000000000000000000006 /* Products */;
    			projectDirPath = "";
    			projectRoot = "";
    			targets = (
    				AA0000000000000000000007 /* Stub */,
    			);
    		};
    		AA000000000000000000000A /* Resources */ = {
    			isa = PBXResourcesBuildPhase;
    			buildActionMask = 2147483647;
    			files = (
    			);
    			runOnlyForDeploymentPostprocessing = 0;
    		};
    		AA0000000000000000000009 /* Sources */ = {
    			isa = PBXSourcesBuildPhase;
    			buildActionMask = 2147483647;
    			files = (
    				AA0000000000000000000001 /* StubApp.swift in Sources */,
    			);
    			runOnlyForDeploymentPostprocessing = 0;
    		};
    		AA000000000000000000000D /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
    				SDKROOT = iphoneos;
    				SWIFT_VERSION = 5.0;
    			};
    			name = Debug;
    		};
    		AA000000000000000000000E /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				CODE_SIGN_STYLE = Automatic;
    				CURRENT_PROJECT_VERSION = 1;
    				DEVELOPMENT_TEAM = "";
    				GENERATE_INFOPLIST_FILE = YES;
    				MARKETING_VERSION = 1.0;
    				PRODUCT_BUNDLE_IDENTIFIER = com.macutil.stub;
    				PRODUCT_NAME = "$(TARGET_NAME)";
    				SWIFT_VERSION = 5.0;
    				TARGETED_DEVICE_FAMILY = "1,2";
    			};
    			name = Debug;
    		};
    		AA0000000000000000000008 /* Build configuration list for PBXNativeTarget "Stub" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				AA000000000000000000000E /* Debug */,
    			);
    			defaultConfigurationIsVisible = 0;
    			defaultConfigurationName = Debug;
    		};
    		AA000000000000000000000C /* Build configuration list for PBXProject "Stub" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				AA000000000000000000000D /* Debug */,
    			);
    			defaultConfigurationIsVisible = 0;
    			defaultConfigurationName = Debug;
    		};
    	};
    	rootObject = AA000000000000000000000B /* Project object */;
    }
    """#
}
