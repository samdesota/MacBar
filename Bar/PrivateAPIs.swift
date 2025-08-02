import Foundation
import CoreGraphics

// MARK: - Private SkyLight API Declarations

// Most of these mirror similarly named functions in the CGS* name space, but as the
// SkyLight Server framework seems to be cropping up more and more with new OS features,
// it may be more "future proof"

// Load the SkyLight framework dynamically
private var skyLightBundle: CFBundle?

// Function pointer types that match the C signatures
private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
private typealias SLSGetActiveSpaceFunc = @convention(c) (Int32) -> UInt64
private typealias SLSCopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> CFArray?
private typealias SLSSpaceGetTypeFunc = @convention(c) (Int32, UInt64) -> Int32
private typealias SLSGetWindowOwnerFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
private typealias SLSCopySpacesForWindowsFunc = @convention(c) (Int32, UInt32, CFArray) -> CFArray?
private typealias SLSCopyWindowsWithOptionsAndTagsFunc = @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> CFArray?

// Function pointers for the private APIs
private var _SLSMainConnectionID: SLSMainConnectionIDFunc?
private var _SLSGetActiveSpace: SLSGetActiveSpaceFunc?
private var _SLSCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunc?
private var _SLSSpaceGetType: SLSSpaceGetTypeFunc?
private var _SLSGetWindowOwner: SLSGetWindowOwnerFunc?
private var _SLSCopySpacesForWindows: SLSCopySpacesForWindowsFunc?
private var _SLSCopyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTagsFunc?

// Initialize function pointers
private func loadPrivateAPIs() {
    // Load the SkyLight framework
    let frameworkURL = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/SkyLight.framework")
    skyLightBundle = CFBundleCreate(kCFAllocatorDefault, frameworkURL)
    
    guard let bundle = skyLightBundle else {
        print("Failed to load SkyLight framework")
        return
    }
    
    // Load function pointers with proper error checking
    if let mainConnectionIDPtr = CFBundleGetFunctionPointerForName(bundle, "SLSMainConnectionID" as CFString) {
        _SLSMainConnectionID = unsafeBitCast(mainConnectionIDPtr, to: SLSMainConnectionIDFunc.self)
        print("✅ Loaded SLSMainConnectionID")
    } else {
        print("❌ Failed to load SLSMainConnectionID")
    }
    
    if let getActiveSpacePtr = CFBundleGetFunctionPointerForName(bundle, "SLSGetActiveSpace" as CFString) {
        _SLSGetActiveSpace = unsafeBitCast(getActiveSpacePtr, to: SLSGetActiveSpaceFunc.self)
        print("✅ Loaded SLSGetActiveSpace")
    } else {
        print("❌ Failed to load SLSGetActiveSpace")
    }
    
    if let copyManagedDisplaySpacesPtr = CFBundleGetFunctionPointerForName(bundle, "SLSCopyManagedDisplaySpaces" as CFString) {
        _SLSCopyManagedDisplaySpaces = unsafeBitCast(copyManagedDisplaySpacesPtr, to: SLSCopyManagedDisplaySpacesFunc.self)
        print("✅ Loaded SLSCopyManagedDisplaySpaces")
    } else {
        print("❌ Failed to load SLSCopyManagedDisplaySpaces")
    }
    
    if let spaceGetTypePtr = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceGetType" as CFString) {
        _SLSSpaceGetType = unsafeBitCast(spaceGetTypePtr, to: SLSSpaceGetTypeFunc.self)
        print("✅ Loaded SLSSpaceGetType")
    } else {
        print("❌ Failed to load SLSSpaceGetType")
    }
    
    if let getWindowOwnerPtr = CFBundleGetFunctionPointerForName(bundle, "SLSGetWindowOwner" as CFString) {
        _SLSGetWindowOwner = unsafeBitCast(getWindowOwnerPtr, to: SLSGetWindowOwnerFunc.self)
        print("✅ Loaded SLSGetWindowOwner")
    } else {
        print("❌ Failed to load SLSGetWindowOwner")
    }
    
    if let copySpacesForWindowsPtr = CFBundleGetFunctionPointerForName(bundle, "SLSCopySpacesForWindows" as CFString) {
        _SLSCopySpacesForWindows = unsafeBitCast(copySpacesForWindowsPtr, to: SLSCopySpacesForWindowsFunc.self)
        print("✅ Loaded SLSCopySpacesForWindows")
    } else {
        print("❌ Failed to load SLSCopySpacesForWindows")
    }
    
    if let copyWindowsWithOptionsAndTagsPtr = CFBundleGetFunctionPointerForName(bundle, "SLSCopyWindowsWithOptionsAndTags" as CFString) {
        _SLSCopyWindowsWithOptionsAndTags = unsafeBitCast(copyWindowsWithOptionsAndTagsPtr, to: SLSCopyWindowsWithOptionsAndTagsFunc.self)
        print("✅ Loaded SLSCopyWindowsWithOptionsAndTags")
    } else {
        print("❌ Failed to load SLSCopyWindowsWithOptionsAndTags")
    }
}

// Public API functions
func SLSMainConnectionID() -> Int32 {
    if _SLSMainConnectionID == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSMainConnectionID else {
        print("❌ SLSMainConnectionID function not available")
        return 0
    }
    
    return function()
}

func SLSGetActiveSpace(_ cid: Int32) -> UInt64 {
    if _SLSGetActiveSpace == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSGetActiveSpace else {
        print("❌ SLSGetActiveSpace function not available")
        return 0
    }
    
    return function(cid)
}

func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray? {
    if _SLSCopyManagedDisplaySpaces == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSCopyManagedDisplaySpaces else {
        print("❌ SLSCopyManagedDisplaySpaces function not available")
        return nil
    }
    
    return function(cid)
}

func SLSSpaceGetType(_ cid: Int32, _ sid: UInt64) -> Int32 {
    if _SLSSpaceGetType == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSSpaceGetType else {
        print("❌ SLSSpaceGetType function not available")
        return 0
    }
    
    return function(cid, sid)
}

func SLSGetWindowOwner(_ cid: Int32, _ wid: CGWindowID) -> Int32 {
    if _SLSGetWindowOwner == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSGetWindowOwner else {
        print("❌ SLSGetWindowOwner function not available")
        return 0
    }
    
    var ownerConnectionID: Int32 = 0
    let result = function(cid, UInt32(wid), &ownerConnectionID)
    
    // CGError codes: 0 = success (kCGErrorSuccess)
    if result == 0 {
        return ownerConnectionID
    } else {
        print("❌ SLSGetWindowOwner failed with error: \(result)")
        return 0
    }
}

func SLSCopySpacesForWindows(_ cid: Int32, _ spaceMask: UInt32, _ windowIDs: CFArray) -> CFArray? {
    if _SLSCopySpacesForWindows == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSCopySpacesForWindows else {
        print("❌ SLSCopySpacesForWindows function not available")
        return nil
    }
    
    return function(cid, spaceMask, windowIDs)
}

func SLSCopyWindowsWithOptionsAndTags(_ cid: Int32, _ owner: UInt32, _ spacesList: CFArray, _ options: UInt32, _ setTags: inout UInt64, _ clearTags: inout UInt64) -> CFArray? {
    if _SLSCopyWindowsWithOptionsAndTags == nil { 
        loadPrivateAPIs() 
    }
    
    guard let function = _SLSCopyWindowsWithOptionsAndTags else {
        print("❌ SLSCopyWindowsWithOptionsAndTags function not available")
        return nil
    }
    
    return function(cid, owner, spacesList, options, &setTags, &clearTags)
}

// MARK: - Space Types
enum SpaceType: Int32 {
    case fullscreen = 4
    case desktop = 0
    case normal = 1
}

// MARK: - Space Info Structure
struct PrivateSpaceInfo {
    let spaceID: UInt64
    let displayUUID: String
    let spaceType: SpaceType
    let spaceIndex: Int
    
    init?(from dictionary: [String: Any]) {
        guard let spaceID = dictionary["64"] as? UInt64,
              let displayUUID = dictionary["Display Identifier"] as? String,
              let spaceTypeRaw = dictionary["type"] as? Int32,
              let spaceType = SpaceType(rawValue: spaceTypeRaw),
              let spaceIndex = dictionary["index"] as? Int else {
            return nil
        }
        
        self.spaceID = spaceID
        self.displayUUID = displayUUID
        self.spaceType = spaceType
        self.spaceIndex = spaceIndex
    }
} 