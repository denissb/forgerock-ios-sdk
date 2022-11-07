// 
//  DeviceBindingCallback.swift
//  FRAuth
//
//  Copyright (c) 2022 ForgeRock. All rights reserved.
//
//  This software may be modified and distributed under the terms
//  of the MIT license. See the LICENSE file for details.
//


import Foundation
import JOSESwift

/**
 * Callback to collect the device binding information
 */
open class DeviceBindingCallback: MultipleValuesCallback {
    
    //  MARK: - Properties
    
    /// The userId received from server
    public var userId: String
    /// The userName received from server
    public var userName: String
    /// The challenge received from server
    public var challenge: String
    /// The authentication type of the journey
    public var deviceBindingAuthenticationType: DeviceBindingAuthenticationType
    // The title to be displayed in biometric prompt
    public var title: String
    // The subtitle to be displayed in biometric prompt
    public var subtitle: String
    // The description to be displayed in biometric prompt
    public var promptDescription: String
    // The timeout to be to expire the biometric authentication
    public var timeout: Int?
    
    /// Jws input key in callback response
    private var jwsKey: String
    /// Device name input key in callback response
    private var deviceNameKey: String
    /// Device id input key in callback response
    private var deviceIdKey: String
    /// Client Error input key in callback response
    private var clientErrorKey: String
    
    //  MARK: - Init
    
    /// Designated initialization method for DeviceBindingCallback
    ///
    /// - Parameter json: JSON object of DeviceBindingCallback
    /// - Throws: AuthError.invalidCallbackResponse for invalid callback response
    required public init(json: [String : Any]) throws {
        guard let callbackType = json[CBConstants.type] as? String else {
            throw AuthError.invalidCallbackResponse(String(describing: json))
        }
        
        guard let outputs = json[CBConstants.output] as? [[String: Any]], let inputs = json[CBConstants.input] as? [[String: Any]] else {
            throw AuthError.invalidCallbackResponse(String(describing: json))
        }
        
        // parse outputs
        var outputDictionary = [String: Any]()
        for output in outputs {
            guard let outputName = output[CBConstants.name] as? String, let outputValue = output[CBConstants.value] else {
                throw AuthError.invalidCallbackResponse("Failed to parse output")
            }
            outputDictionary[outputName] = outputValue
        }
        
        guard let userId = outputDictionary[CBConstants.userId] as? String else {
            throw AuthError.invalidCallbackResponse("Missing userId")
        }
        self.userId = userId
        
        guard let userName = outputDictionary[CBConstants.username] as? String else {
            throw AuthError.invalidCallbackResponse("Missing username")
        }
        self.userName = userName
        
        guard let outputValue = outputDictionary[CBConstants.authenticationType] as? String, let deviceBindingAuthenticationType = DeviceBindingAuthenticationType(rawValue: outputValue) else {
            throw AuthError.invalidCallbackResponse("Missing authenticationType")
        }
        self.deviceBindingAuthenticationType = deviceBindingAuthenticationType
        
        guard let challenge = outputDictionary[CBConstants.challenge] as? String else {
            throw AuthError.invalidCallbackResponse("Missing challenge")
        }
        self.challenge = challenge
        
        guard let title = outputDictionary[CBConstants.title] as? String else {
            throw AuthError.invalidCallbackResponse("Missing title")
        }
        self.title = title
        
        guard let subtitle = outputDictionary[CBConstants.subtitle] as? String else {
            throw AuthError.invalidCallbackResponse("Missing subtitle")
        }
        self.subtitle = subtitle
        
        guard let promptDescription = outputDictionary[CBConstants.description] as? String else {
            throw AuthError.invalidCallbackResponse("Missing description")
        }
        self.promptDescription = promptDescription
        
        self.timeout = outputDictionary[CBConstants.timeout] as? Int
        
        //parse inputs
        var inputNames = [String]()
        for input in inputs {
            guard let inputName = input[CBConstants.name] as? String else {
                throw AuthError.invalidCallbackResponse("Failed to parse input")
            }
            inputNames.append(inputName)
        }
        
        guard let jwsKey = inputNames.filter({ $0.contains(CBConstants.jws) }).first else {
            throw AuthError.invalidCallbackResponse("Missing jwsKey")
        }
        self.jwsKey = jwsKey
        
        guard let deviceNameKey = inputNames.filter({ $0.contains(CBConstants.deviceName) }).first else {
            throw AuthError.invalidCallbackResponse("Missing deviceNameKey")
        }
        self.deviceNameKey = deviceNameKey
        
        guard let deviceIdKey = inputNames.filter({ $0.contains(CBConstants.deviceId) }).first else {
            throw AuthError.invalidCallbackResponse("Missing deviceIdKey")
        }
        self.deviceIdKey = deviceIdKey
        
        guard let clientErrorKey = inputNames.filter({ $0.contains(CBConstants.clientError) }).first else {
            throw AuthError.invalidCallbackResponse("Missing clientErrorKey")
        }
        self.clientErrorKey = clientErrorKey
        
        try super.init(json: json)
        type = callbackType
        response = json
    }
    
    
    /// Bind the device.
    /// - Parameter completion Completion block for Device binding result callback
    open func bind(completion: @escaping DeviceBindingResultCallback) {
        execute(authInterface: nil, deviceId: nil, completion)
    }
    
    
    /// Helper method to execute binding , signing, show biometric prompt.
    /// - Parameter authInterface: Interface to find the Authentication Type - provide nil to default to getDeviceBindingAuthenticator()
    /// - Parameter deviceId: Interface to find the Authentication Type - provide nil to default to FRDevice.currentDevice?.identifier.getIdentifier()
    /// - Parameter completion: completion Completion block for Device binding result callback
    internal func execute(authInterface: DeviceAuthenticator?,
                          deviceId: String?,
                          _ completion: @escaping DeviceBindingResultCallback) {
        let newAuthInterface = authInterface ?? getDeviceBindingAuthenticator()
        let newDeviceId = deviceId ?? FRDevice.currentDevice?.identifier.getIdentifier()
        
        guard newAuthInterface.isSupported() else {
            handleException(status: .unsupported(errorMessage: nil), completion: completion)
            return
        }
        
        let startTime = Date()
        let timeout = timeout ?? 60
        
        do {
            let kid = UUID().uuidString
            let keyPair = try newAuthInterface.generateKeys()
            
            // Authentication will be triggered during signing if necessary
            let jws = try newAuthInterface.sign(keyPair: keyPair, kid: kid, userId: self.userId, challenge: self.challenge, expiration: self.getExpiration())
            
            // Check for timeout
            let delta = Date().timeIntervalSince(startTime)
            if(delta > Double(timeout)) {
                self.handleException(status: .timeout, completion: completion)
                return
            }
            
            // If no errors, set the input values and complete with success
            self.setJws(jws)
            if let newDeviceId = newDeviceId {
                self.setDeviceId(newDeviceId)
            }
            completion(.success)
        } catch JOSESwiftError.localAuthenticationFailed {
            self.handleException(status: .abort, completion: completion)
        } catch let error {
            self.handleException(status: .unsupported(errorMessage: error.localizedDescription), completion: completion)
        }
    }
    
    
    /// Handle all the errors for the device binding.
    /// - Parameter status: Device binding status
    /// - Parameter completion: Completion block Device binding result callback
    open func handleException(status: DeviceBindingStatus, completion: @escaping DeviceBindingResultCallback) {
        // Remove the private key if already generated
        KeyAware.deleteKey(keyAlias: KeyAware.getKeyAlias(keyName: userId))
        
        setClientError(status.clientError)
        FRLog.e(status.errorMessage)
        completion(.failure(status))
    }
    
    
    /// Create the interface for the Authentication type(biometricOnly, biometricAllowFallback, none)
    open func getDeviceBindingAuthenticator() -> DeviceAuthenticator {
        return AuthenticatorFactory.getAuthenticator(userId: userId, authentication: deviceBindingAuthenticationType, title: title, subtitle: subtitle, description: promptDescription, keyAware: nil)
    }
    
    
    /// Get Expiration date for the signed token, claim "exp" will be set to the JWS
    open func getExpiration() -> Date {
        return Date().addingTimeInterval(Double(timeout ?? 60))
    }
    
    
    //  MARK: - Set values
    
    /// Sets `jws` value in callback response
    /// - Parameter jws: String value of `jws`]
    public func setJws(_ jws: String) {
        self.inputValues[self.jwsKey] = jws
    }
    
    
    /// Sets `deviceName` value in callback response
    /// - Parameter deviceName: String value of `deviceName`]
    public func setDeviceName(_ deviceName: String) {
        self.inputValues[self.deviceNameKey] = deviceName
    }
    
    
    /// Sets `deviceId` value in callback response
    /// - Parameter deviceId: String value of `deviceId`]
    public func setDeviceId(_ deviceId: String) {
        self.inputValues[self.deviceIdKey] = deviceId
    }
    
    
    /// Sets `clientError` value in callback response
    /// - Parameter clientError: String value of `clientError`]
    public func setClientError(_ clientError: String) {
        self.inputValues[self.clientErrorKey] = clientError
    }
}


/// Convert authentication type string received from server to authentication type enum
public enum DeviceBindingAuthenticationType: String, Codable {
    case biometricOnly = "BIOMETRIC_ONLY"
    case biometricAllowFallback = "BIOMETRIC_ALLOW_FALLBACK"
    case none = "NONE"
}
