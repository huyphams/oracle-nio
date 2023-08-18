import NIOCore
import Crypto

struct OracleFrontendMessageEncoder {
    private enum State {
        case flushed
        case writable
    }

    private var buffer: ByteBuffer
    private var state: State = .writable
    private var capabilities: Capabilities


    init(buffer: ByteBuffer, capabilities: Capabilities) {
        self.buffer = buffer
        self.capabilities = capabilities
    }

    mutating func flush() -> ByteBuffer {
        self.state = .flushed
        return self.buffer
    }

    mutating func encode(_ message: OracleFrontendMessage) {
        self.clearIfNeeded()

        switch message {
        case .connect(let connect):
            Self.createMessage(
                connect, capabilities: self.capabilities, out: &self.buffer
            )
        case .protocol(let `protocol`):
            Self.createMessage(
                `protocol`, capabilities: self.capabilities, out: &self.buffer
            )
        case .dataTypes(let dataTypes):
            Self.createMessage(
                dataTypes, capabilities: self.capabilities, out: &self.buffer
            )
        }
    }

    mutating func marker() {
        self.clearIfNeeded()

        self.buffer.startRequest(packetType: .marker)
        self.buffer.writeMultipleIntegers(
            UInt8(1), UInt8(0), Constants.TNS_MARKER_TYPE_RESET
        )
        self.buffer.endRequest(
            packetType: .marker, capabilities: self.capabilities
        )
    }

    mutating func authenticationPhaseOne(authContext: AuthContext) {
        self.clearIfNeeded()

        // 1. Setup

        let newPassword = authContext.newPassword

        // TODO: DRCP support
        // context: if drcp is used, use purity = NEW as the default purity for
        // standalone connections and purity = SELF for connections that belong
        // to a pool
        // for now just use the value from description

        let authMode = Self.configureAuthMode(
            from: authContext.mode,
            newPassword: newPassword
        )

        // 2. message preparation

        let numberOfPairs: UInt32 = 5

        self.buffer.startRequest()

        Self.writeBasicAuthData(
            authContext: authContext, authPhase: .one, authMode: authMode,
            pairsCount: numberOfPairs, out: &self.buffer
        )

        // 3. write key/value pairs
        Self.writeKeyValuePair(
            key: "AUTH_TERMINAL",
            value: ConnectConstants.default.terminalName,
            out: &self.buffer
        )
        Self.writeKeyValuePair(
            key: "AUTH_PROGRAM_NM",
            value: ConnectConstants.default.programName,
            out: &self.buffer
        )
        Self.writeKeyValuePair(
            key: "AUTH_MACHINE",
            value: ConnectConstants.default.machineName,
            out: &self.buffer
        )
        Self.writeKeyValuePair(
            key: "AUTH_PID",
            value: String(ConnectConstants.default.pid),
            out: &self.buffer
        )
        Self.writeKeyValuePair(
            key: "AUTH_SID",
            value: ConnectConstants.default.username,
            out: &self.buffer
        )

        self.buffer.endRequest(capabilities: self.capabilities)
    }

    mutating func authenticationPhaseTwo(
        authContext: AuthContext, parameters: OracleBackendMessage.Parameter
    ) throws {
        self.clearIfNeeded()

        let verifierType = parameters["AUTH_VFR_DATA"]?.flags

        var numberOfPairs: UInt32 = 3

        // user/password authentication
        numberOfPairs += 2
        var authMode = Self.configureAuthMode(
            from: authContext.mode, newPassword: authContext.newPassword
        )
        authMode |= Constants.TNS_AUTH_MODE_WITH_PASSWORD
        let verifier11g: Bool
        if
            [
                Constants.TNS_VERIFIER_TYPE_11G_1,
                Constants.TNS_VERIFIER_TYPE_11G_2
            ].contains(verifierType) {
            verifier11g = true
        } else if verifierType != Constants.TNS_VERIFIER_TYPE_12C {
            // TODO: refactor error
            throw OracleError.ErrorType.unsupportedVerifierType
        } else {
            verifier11g = false
            numberOfPairs += 1
        }
        let (
            sessionKey, speedyKey, encodedPassword, encodedNewPassword
        ) = try Self.generateVerifier(
            authContext: authContext, parameters: parameters, verifier11g
        )

        // determine which other key/value pairs to write
        if authContext.newPassword != nil {
            numberOfPairs += 1
            authMode |= Constants.TNS_AUTH_MODE_CHANGE_PASSWORD
        }
        if authContext.description.purity != .default {
            numberOfPairs += 1
        }

        self.buffer.startRequest()

        Self.writeBasicAuthData(
            authContext: authContext, authPhase: .two, authMode: authMode,
            pairsCount: numberOfPairs, out: &self.buffer
        )

        Self.writeKeyValuePair(
            key: "AUTH_SESSKEY", value: sessionKey, flags: 1, out: &self.buffer
        )
        Self.writeKeyValuePair(
            key: "AUTH_PASSWORD", value: encodedPassword, out: &self.buffer
        )
        if !verifier11g {
            guard let speedyKey else {
                preconditionFailure("speedy key needs to be generated before running authentication phase two")
            }
            Self.writeKeyValuePair(
                key: "AUTH_PBKDF2_SPEEDY_KEY",
                value: speedyKey,
                out: &self.buffer
            )
        }
        if let encodedNewPassword {
            Self.writeKeyValuePair(
                key: "AUTH_NEWPASSWORD",
                value: encodedNewPassword,
                out: &self.buffer
            )
        }
        Self.writeKeyValuePair(
            key: "SESSION_CLIENT_CHARSET", value: "873", out: &self.buffer
        )
        let driverName = "\(Constants.DRIVER_NAME) thn : \(Constants.VERSION)"
        Self.writeKeyValuePair(
            key: "SESSION_CLIENT_DRIVER_NAME",
            value: driverName,
            out: &self.buffer
        )
        Self.writeKeyValuePair(
            key: "SESSION_CLIENT_VERSION",
            value: "\(Constants.VERSION_CODE)",
            out: &self.buffer
        )
        if authContext.description.purity != .default {
            Self.writeKeyValuePair(
                key: "AUTH_KPPL_PURITY",
                value: String(authContext.description.purity.rawValue),
                flags: 1,
                out: &self.buffer
            )
        }

        self.buffer.endRequest(capabilities: self.capabilities)
    }

    mutating func execute(
        queryContext: ExtendedQueryContext,
        cleanupContext: CleanupContext
    ) {
        self.clearIfNeeded()

        let query = queryContext.query
        let queryOptions = queryContext.options

        // 1. options
        var options: UInt32 = 0
        var dmlOptions: UInt32 = 0
        var parametersCount: UInt32 = 0
        var iterationsCount: UInt32 = 1

        if !queryContext.requiresFullExecute && query.binds.count != 0 {
            parametersCount = .init(query.binds.count)
        }
        if queryContext.requiresDefine {
            options |= Constants.TNS_EXEC_OPTION_DEFINE
        } else if !query.sql.isEmpty {
            dmlOptions = Constants.TNS_EXEC_OPTION_IMPLICIT_RESULTSET
            options |= Constants.TNS_EXEC_OPTION_EXECUTE
        }
        if queryContext.cursorID == 0 || queryContext.statement.isDDL {
            options |= Constants.TNS_EXEC_OPTION_PARSE
        }
        if queryContext.statement.isQuery {
            if queryOptions.prefetchRows > 0 {
                options |= Constants.TNS_EXEC_OPTION_FETCH
            }
            if queryContext.cursorID == 0 || queryContext.requiresDefine {
                iterationsCount = UInt32(queryOptions.prefetchRows)
            } else {
                iterationsCount = 0
            }
        }
        if !queryContext.statement.isPlSQL {
            options |= Constants.TNS_EXEC_OPTION_NOT_PLSQL
        } else if queryContext.statement.isPlSQL && parametersCount > 0 {
            options |= Constants.TNS_EXEC_OPTION_PLSQL_BIND
        }
        if parametersCount > 0 {
            options |= Constants.TNS_EXEC_OPTION_BIND
        }
        if queryOptions.autoCommit {
            options |= Constants.TNS_EXEC_OPTION_COMMIT
        }

        self.buffer.startRequest()

        // 2. write piggybacks, if needed
        self.writePiggybacks(context: cleanupContext)

        // 3 write function code
        self.buffer.writeInteger(MessageType.function.rawValue)
        self.buffer.writeInteger(Constants.TNS_FUNC_EXECUTE)
        self.buffer.writeSequenceNumber(with: queryContext.sequenceNumber)
        queryContext.sequenceNumber += 1

        // 4. write body of message
        self.buffer.writeUB4(options) // execute options
        self.buffer.writeUB4(UInt32(queryContext.cursorID)) // cursor ID
        if queryContext.cursorID == 0 || queryContext.statement.isDDL {
            self.buffer.writeInteger(UInt8(1)) // pointer (cursor ID)
            self.buffer.writeUB4(queryContext.sqlLength)
        } else {
            self.buffer.writeInteger(UInt8(0)) // pointer (cursor ID)
            self.buffer.writeUB4(0)
        }
        self.buffer.writeInteger(UInt8(1)) // pointer (vector)
        self.buffer.writeUB4(13) // al8i4 array length
        self.buffer.writeInteger(UInt8(0)) // pointer (al8o4)
        self.buffer.writeInteger(UInt8(0)) // pointer (al8o4l)
        self.buffer.writeUB4(0) // prefetch buffer size
        self.buffer.writeUB4(iterationsCount) // prefetch number of rows
        self.buffer.writeUB4(Constants.TNS_MAX_LONG_LENGTH) // maximum long size
        if parametersCount == 0 {
            self.buffer.writeInteger(UInt8(0)) // pointer (binds)
            self.buffer.writeUB4(0) // number of binds
        } else {
            self.buffer.writeInteger(UInt8(1)) // pointer (binds)
            self.buffer.writeUB4(parametersCount) // number of binds
        }
        self.buffer.writeInteger(UInt8(0)) // pointer (al8app)
        self.buffer.writeInteger(UInt8(0)) // pointer (al8txn)
        self.buffer.writeInteger(UInt8(0)) // pointer (al8txl)
        self.buffer.writeInteger(UInt8(0)) // pointer (al8kv)
        self.buffer.writeInteger(UInt8(0)) // pointer (al8kvl)
        if queryContext.requiresDefine {
            self.buffer.writeInteger(UInt8(1)) // pointer (al8doac)
            self.buffer.writeUB4(UInt32(queryContext.queryVariables.count)) // number of defines
        } else {
            self.buffer.writeInteger(UInt8(0))
            self.buffer.writeUB4(0)
        }
        self.buffer.writeUB4(0) // registration id
        self.buffer.writeInteger(UInt8(0)) // pointer (al8objlist)
        self.buffer.writeInteger(UInt8(1)) // pointer (al8objlen)
        self.buffer.writeInteger(UInt8(0)) // pointer (al8blv)
        self.buffer.writeUB4(0) // al8blvl
        self.buffer.writeInteger(UInt8(0)) // pointer (al8dnam)
        self.buffer.writeUB4(0) // al8dnaml
        self.buffer.writeUB4(0) // al8regid_msb
        if queryOptions.arrayDMLRowCounts {
            self.buffer.writeInteger(UInt8(1)) // pointer (al8pidmlrc)
            self.buffer.writeUB4(1) // al8pidmlrcbl / numberOfExecutions
            self.buffer.writeInteger(UInt8(1)) // pointer (al8pidmlrcl)
        } else {
            self.buffer.writeInteger(UInt8(0)) // pointer (al8pidmlrc)
            self.buffer.writeUB4(0) // al8pidmlrcbl
            self.buffer.writeInteger(UInt8(0)) // pointer (al8pidmlrcl)
        }
        if self.capabilities.ttcFieldVersion 
            >= Constants.TNS_CCAP_FIELD_VERSION_12_2 {
            self.buffer.writeInteger(UInt8(0)) // pointer (al8sqlsig)
            self.buffer.writeUB4(0) // SQL signature length
            self.buffer.writeInteger(UInt8(0)) // pointer (SQL ID)
            self.buffer.writeUB4(0) // allocated size of SQL ID
            self.buffer.writeInteger(UInt8(0)) // pointer (length of SQL ID)
            if self.capabilities.ttcFieldVersion 
                >= Constants.TNS_CCAP_FIELD_VERSION_12_2_EXT1 {
                self.buffer.writeInteger(UInt8(0)) // pointer (chunk ids)
                self.buffer.writeUB4(0) // number of chunk ids
            }
        }
        if queryContext.cursorID == 0 || queryContext.statement.isDDL {
            self.buffer.writeBytes(queryContext.query.sql.bytes)
            self.buffer.writeUB4(1) // al8i4[0] parse
        } else {
            self.buffer.writeUB4(0) // al8i4[0] parse
        }
        if queryContext.statement.isQuery {
            if queryContext.cursorID == 0 {
                self.buffer.writeUB4(0) // al8i4[1] execution count
            } else {
                self.buffer.writeUB4(iterationsCount)
            }
        } else {
            self.buffer.writeUB4(1) // al8i4[1] execution count
        }
        self.buffer.writeUB4(0) // al8i4[2]
        self.buffer.writeUB4(0) // al8i4[3]
        self.buffer.writeUB4(0) // al8i4[4]
        self.buffer.writeUB4(0) // al8i4[5] SCN (part 1)
        self.buffer.writeUB4(0) // al8i4[6] SCN (part 2)
        self.buffer.writeUB4(
            queryContext.statement.isQuery ? 1 : 0
        ) // al8i4[7] is query
        self.buffer.writeUB4(0) // al8i4[8]
        self.buffer.writeUB4(dmlOptions) // al8i4[9] DML row counts/implicit
        self.buffer.writeUB4(0) // al8i4[10]
        self.buffer.writeUB4(0) // al8i4[11]
        self.buffer.writeUB4(0) // al8i4[12]
        if queryContext.requiresDefine {
            self.writeColumnMetadata(queryContext.query.binds.metadata)
        } else if parametersCount > 0 {
            self.writeBindParameters(queryContext.query.binds)
        }

        self.buffer.endRequest(capabilities: self.capabilities)
    }

    mutating func logoff() {
        self.clearIfNeeded()

        self.buffer.startRequest()

        // write function code
        self.buffer.writeInteger(MessageType.function.rawValue)
        self.buffer.writeInteger(Constants.TNS_FUNC_LOGOFF)
        self.buffer.writeSequenceNumber()

        self.buffer.endRequest(capabilities: self.capabilities)
    }

    mutating func close() {
        self.clearIfNeeded()

        self.buffer.startRequest(
            packetType: .data, dataFlags: Constants.TNS_DATA_FLAGS_EOF
        )
        self.buffer.endRequest(capabilities: self.capabilities)
    }

    // MARK: - Private Methods -

    private mutating func clearIfNeeded() {
        switch self.state {
        case .flushed:
            self.state = .writable
            self.buffer.clear()
        case .writable:
            break
        }
    }

    private static func createMessage(
        _ message: OracleFrontendMessage.PayloadEncodable,
        capabilities: Capabilities,
        out buffer: inout ByteBuffer
    ) {
        buffer.startRequest(packetType: message.packetType)
        message.encode(into: &buffer, capabilities: capabilities)
        buffer.endRequest(
            packetType: message.packetType, capabilities: capabilities
        )
    }
}

// MARK: - Authentication related stuff

extension OracleFrontendMessageEncoder {

    private static func configureAuthMode(
        from mode: UInt32 , newPassword: String? = nil
    ) -> UInt32 {
        var authMode: UInt32 = 0

        // Set authentication mode
        if newPassword == nil {
            authMode = Constants.TNS_AUTH_MODE_LOGON
        }
        if AuthenticationMode.sysDBA.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSDBA
        }
        if AuthenticationMode.sysOPER.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSOPER
        }
        if AuthenticationMode.sysASM.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSASM
        }
        if AuthenticationMode.sysBKP.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSBKP
        }
        if AuthenticationMode.sysDGD.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSDGD
        }
        if AuthenticationMode.sysKMT.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSKMT
        }
        if AuthenticationMode.sysRAC.compare(with: mode) {
            authMode |= Constants.TNS_AUTH_MODE_SYSRAC
        }

        return authMode
    }

    private static func generateVerifier(
        authContext: AuthContext,
        parameters: OracleBackendMessage.Parameter,
        _ verifier11g: Bool
    ) throws -> (
        sessionKey: String,
        speedyKey: String?,
        encodedPassword: String,
        encodedNewPassword: String?
    ) {
        let sessionKey: String
        let speedyKey: String?
        let encodedPassword: String
        let encodedNewPassword: String?

        let password = authContext.password.bytes

        guard let authVFRData = parameters["AUTH_VFR_DATA"] else {
            // TODO: better error handling
            preconditionFailure("AUTH_VFR_DATA needs to be in \(parameters)")
        }
        let verifierData = Self.hexToBytes(string: authVFRData.value)
        let keyLength: Int

        // create password hash
        let passwordHash: [UInt8]
        let passwordKey: [UInt8]?
        if verifier11g {
            keyLength = 24
            var sha = Insecure.SHA1()
            sha.update(data: password)
            sha.update(data: verifierData)
            passwordHash = sha.finalize() + [UInt8](repeating: 0, count: 4)
            passwordKey = nil
        } else {
            keyLength = 32
            guard
                let vgenCountStr = parameters["AUTH_PBKDF2_VGEN_COUNT"],
                let vgenCount = Int(vgenCountStr.value)
            else {
                // TODO: better error handling
                preconditionFailure("AUTH_PBKDF2_VGEN_COUNT needs to be in \(parameters)")
            }
            let iterations = vgenCount
            let speedyKey = "AUTH_PBKDF2_SPEEDY_KEY".bytes
            let salt = verifierData + speedyKey
            passwordKey = try getDerivedKey(
                key: password,
                salt: salt, length: 64, iterations: iterations
            )
            var sha = SHA512()
            sha.update(data: passwordKey!)
            sha.update(data: verifierData)
            passwordHash = Array(sha.finalize().prefix(32))
        }

        // decrypt first half of session key
        guard let authSessionKey = parameters["AUTH_SESSKEY"] else {
            // TODO: better error handling
            preconditionFailure("AUTH_SESSKEY needs to be in \(parameters)")
        }
        let encodedServerKey = Self.hexToBytes(string: authSessionKey.value)
        let sessionKeyPartA = try decryptCBC(passwordHash, encodedServerKey)

        // generate second half of session key
        let sessionKeyPartB = [UInt8].random(count: 32)
        let encodedClientKey = try encryptCBC(passwordHash, sessionKeyPartB)
        sessionKey = String(
            encodedClientKey.toHexString().uppercased().prefix(64)
        )

        // create session key from combo key
        guard let cskSalt = parameters["AUTH_PBKDF2_CSK_SALT"] else {
            // TODO: better error handling
            preconditionFailure("AUTH_PBKDF2_CSK_SALT needs to be in \(parameters)")
        }
        let mixingSalt = Self.hexToBytes(string: cskSalt.value)
        guard
            let sderCountStr = parameters["AUTH_PBKDF2_SDER_COUNT"],
            let sderCount = Int(sderCountStr.value)
        else {
            preconditionFailure("AUTH_PBKDF2_SDER_COUNT needs to be in \(parameters)")
        }
        let iterations = sderCount
        let comboKey = Array(
            sessionKeyPartB.prefix(keyLength) +
            sessionKeyPartA.prefix(keyLength)
        )
        let derivedKey = try getDerivedKey(
            key: comboKey.toHexString().uppercased().bytes,
            salt: mixingSalt, length: keyLength, iterations: iterations
        )

        // generate speedy key for 12c verifiers
        if !verifier11g, let passwordKey {
            let salt = [UInt8].random(count: 16)
            let speedyKeyCBC = try encryptCBC(derivedKey, salt + passwordKey)
            speedyKey = Array(speedyKeyCBC.prefix(80))
                .toHexString()
                .uppercased()
        } else {
            speedyKey = nil
        }

        // encrypt password
        let pwSalt = [UInt8].random(count: 16)
        let passwordWithSalt = pwSalt + password
        let encryptedPassword = try encryptCBC(derivedKey, passwordWithSalt)
        encodedPassword = encryptedPassword.toHexString().uppercased()

        // encrypt new password
        if let newPassword = authContext.newPassword?.bytes {
            let newPasswordWithSalt = pwSalt + newPassword
            let encryptedNewPassword = try encryptCBC(derivedKey, newPasswordWithSalt)
            encodedNewPassword = encryptedNewPassword.toHexString().uppercased()
        } else {
            encodedNewPassword = nil
        }

        return (sessionKey, speedyKey, encodedPassword, encodedNewPassword)
    }

    private static func writeKeyValuePair(
        key: String, value: String, flags: UInt32 = 0,
        out buffer: inout ByteBuffer
    ) {
        let keyBytes = key.bytes
        let keyLength = keyBytes.count
        let valueBytes = value.bytes
        let valueLength = valueBytes.count
        buffer.writeUB4(UInt32(keyLength))
        buffer.writeBytesAndLength(keyBytes)
        buffer.writeUB4(UInt32(valueLength))
        if valueLength > 0 {
            buffer.writeBytesAndLength(valueBytes)
        }
        buffer.writeUB4(flags)
    }

    private static func hexToBytes(string: String) -> [UInt8] {
        let stringArray = Array(string)
        var data = [UInt8]()
        for i in stride(from: 0, to: string.count, by: 2) {
            let pair: String = String(stringArray[i]) + String(stringArray[i+1])
            if let byte = UInt8(pair, radix: 16) {
                data.append(byte)
            } else {
                fatalError("Couldn't create byte from hex value: \(pair)")
            }
        }
        return data
    }

    private static func writeBasicAuthData(
        authContext: AuthContext,
        authPhase: Constants.AuthPhase,
        authMode: UInt32,
        pairsCount: UInt32,
        out buffer: inout ByteBuffer
    ) {
        let username = authContext.username.bytes
        let usernameLength = authContext.username.count
        let hasUser: UInt8 = authContext.username.count > 0 ? 1 : 0

        // 1. write function code
        buffer.writeInteger(MessageType.function.rawValue)
        buffer.writeInteger(authPhase.rawValue)
        buffer.writeSequenceNumber(with: authPhase == .one ? 0 : 1)

        // 2. write basic data
        buffer.writeInteger(hasUser) // pointer (authuser)
        buffer.writeUB4(UInt32(usernameLength))
        buffer.writeUB4(authMode) // authentication mode
        buffer.writeInteger(UInt8(1)) // pointer (authiv1)
        buffer.writeUB4(pairsCount) // number of key/value pairs
        buffer.writeInteger(UInt8(1)) // pointer (authovl)
        buffer.writeInteger(UInt8(1)) // pointer (authovln)
        if hasUser != 0 {
            buffer.writeBytes(username)
        }
    }

}

// MARK: Data/Query related stuff

extension OracleFrontendMessageEncoder {
    private mutating func writePiggybacks(context: CleanupContext) {
        if 
            let cursorsToClose = context.cursorsToClose,
            !cursorsToClose.isEmpty 
        {
            self.writeCloseCursorsPiggyback(cursorsToClose)
            context.cursorsToClose = nil
        }
        if context.tempLOBsTotalSize > 0 {
            if let tempLOBsToClose = context.tempLOBsToClose {
                self.writeCloseTempLOBsPiggyback(
                    tempLOBsToClose, totalSize: context.tempLOBsTotalSize
                )
                context.tempLOBsToClose = nil
            }
            context.tempLOBsTotalSize = 0
        }
    }

    private mutating func writePiggybackCode(code: UInt8) {
        self.buffer.writeInteger(UInt8(MessageType.piggyback.rawValue))
        self.buffer.writeInteger(code)
        self.buffer.writeSequenceNumber()
        if self.capabilities.ttcFieldVersion 
            >= Constants.TNS_CCAP_FIELD_VERSION_23_1_EXT_1 {
            self.buffer.writeUB8(0) // token number
        }
    }

    private mutating func writeCloseCursorsPiggyback(
        _ cursorsToClose: [UInt16]
    ) {
        self.writePiggybackCode(code: Constants.TNS_FUNC_CLOSE_CURSORS)
        self.buffer.writeInteger(UInt8(1)) // pointer
        self.buffer.writeUB4(UInt32(cursorsToClose.count))
        for cursorID in cursorsToClose {
            self.buffer.writeUB4(UInt32(cursorID))
        }
    }

    private mutating func writeCloseTempLOBsPiggyback(
        _ tempLOBsToClose: [[UInt8]],
        totalSize tempLOBsTotalSize: Int
    ) {
        self.writePiggybackCode(code: Constants.TNS_FUNC_LOB_OP)
        let opCode = Constants.TNS_LOB_OP_FREE_TEMP | Constants.TNS_LOB_OP_ARRAY

        // temp lob data
        self.buffer.writeInteger(UInt8(1)) // pointer
        self.buffer.writeUB4(UInt32(tempLOBsTotalSize))
        self.buffer.writeInteger(UInt8(0)) // destination lob locator
        self.buffer.writeUB4(0)
        self.buffer.writeUB4(0) // source lob locator
        self.buffer.writeUB4(0)
        self.buffer.writeInteger(UInt8(0)) // source lob offset
        self.buffer.writeInteger(UInt8(0)) // destination lob offset
        self.buffer.writeInteger(UInt8(0)) // charset
        self.buffer.writeUB4(opCode)
        self.buffer.writeInteger(UInt8(0)) // scn
        self.buffer.writeUB4(0) // losbscn
        self.buffer.writeUB8(0) // lobscnl
        self.buffer.writeUB8(0)
        self.buffer.writeInteger(UInt8(0))

        // array lob fields
        self.buffer.writeInteger(UInt8(0))
        self.buffer.writeUB4(0)
        self.buffer.writeInteger(UInt8(0))
        self.buffer.writeUB4(0)
        self.buffer.writeInteger(UInt8(0))
        self.buffer.writeUB4(0)

        for lob in tempLOBsToClose {
            buffer.writeBytes(lob)
        }
    }

    private mutating func writeBindParameters(_ binds: OracleBindings) {
        var hasData = !binds.metadata.isEmpty
        self.writeColumnMetadata(binds.metadata)

        // write parameter values unless statement contains only return binds
        if hasData {
            self.buffer.writeInteger(MessageType.rowData.rawValue)
            self.writeBindParameterRow(bindings: binds)
        }
    }

    private mutating func writeColumnMetadata(
        _ metadata: [OracleBindings.Metadata]
    ) {
        for info in metadata {
            var oracleType = info.dataType.oracleType
            var bufferSize = info.bufferSize
            if [.rowID, .uRowID].contains(oracleType) {
                oracleType = .varchar
                bufferSize = Constants.TNS_MAX_UROWID_LENGTH
            }
            var flag: UInt8 = Constants.TNS_BIND_USE_INDICATORS
            if info.isArray {
                flag |= Constants.TNS_BIND_ARRAY
            }
            var contFlag: UInt32 = 0
            var lobPrefetchLength: UInt32 = 0
            if [.blob, .clob].contains(oracleType) {
                contFlag = Constants.TNS_LOB_PREFETCH_FLAG
            } else if oracleType == .json {
                contFlag = Constants.TNS_LOB_PREFETCH_FLAG
                bufferSize = Constants.TNS_JSON_MAX_LENGTH
                lobPrefetchLength = Constants.TNS_JSON_MAX_LENGTH
            }
            self.buffer.writeInteger(UInt8(oracleType?.rawValue ?? 0))
            self.buffer.writeInteger(flag)
            // precision and scale are always written as zero as the server
            // expects that and complains if any other value is sent!
            self.buffer.writeInteger(UInt8(0))
            self.buffer.writeInteger(UInt8(0))
            if bufferSize > self.capabilities.maxStringSize {
                self.buffer.writeUB4(Constants.TNS_MAX_LONG_LENGTH)
            } else {
                self.buffer.writeUB4(bufferSize)
            }
            if info.isArray {
                self.buffer.writeUB4(UInt32(info.maxArraySize))
            } else {
                self.buffer.writeUB4(0) // max num elements
            }
            self.buffer.writeUB8(UInt64(contFlag))
            self.buffer.writeUB4(0) // OID
            self.buffer.writeUB4(0) // version
            if info.dataType.csfrm != 0 {
                self.buffer.writeUB4(UInt32(Constants.TNS_CHARSET_UTF8))
            } else {
                self.buffer.writeUB4(0)
            }
            self.buffer.writeInteger(info.dataType.csfrm)
            self.buffer.writeUB4(lobPrefetchLength) // max chars (LOB prefetch)
            if self.capabilities.ttcFieldVersion
                >= Constants.TNS_CCAP_FIELD_VERSION_12_2 {
                self.buffer.writeUB4(0) // oaccolid
            }
        }
    }

    private mutating func writeBindParameterRow(bindings: OracleBindings) {
        self.buffer.writeImmutableBuffer(bindings.bytes)
    }

}