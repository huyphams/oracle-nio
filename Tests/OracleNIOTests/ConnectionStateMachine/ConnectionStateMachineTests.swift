//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2024 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import NIOCore
import NIOEmbedded
import XCTest

@testable import OracleNIO

final class ConnectionStateMachineTests: XCTestCase {
    func testQueuedTasksAreExecuted() throws {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise1 = EmbeddedEventLoop().makePromise(of: Void.self)
        promise1.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let promise2 = EmbeddedEventLoop().makePromise(of: Void.self)
        promise2.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let success = OracleBackendMessage.Status(callStatus: 1, endToEndSequenceNumber: 0)

        XCTAssertEqual(state.enqueue(task: .ping(promise1)), .sendPing)
        XCTAssertEqual(state.enqueue(task: .ping(promise2)), .wait)
        XCTAssertEqual(state.statusReceived(success), .succeedPing(promise1))
        XCTAssertEqual(state.readyForStatementReceived(), .sendPing)
    }

    func testFailedPingDoesNotLeak() {
        var state = ConnectionStateMachine(.readyForStatement)
        let atomic = ManagedAtomic(false)
        let pingPromise = EmbeddedEventLoop().makePromise(of: Void.self)
        pingPromise.futureResult.whenFailure { _ in
            atomic.store(true, ordering: .relaxed)
        }

        XCTAssertEqual(state.enqueue(task: .ping(pingPromise)), .sendPing)
        XCTAssertEqual(
            state.errorHappened(.uncleanShutdown),
            .closeConnectionAndCleanup(
                .init(
                    action: .fireChannelInactive,
                    tasks: [],
                    error: .uncleanShutdown,
                    read: false,
                    closePromise: nil
                )
            )
        )
        XCTAssertTrue(atomic.load(ordering: .relaxed))
    }

    func testFailedLOBDoesNotLeak() {
        var state = ConnectionStateMachine(.readyForStatement)
        let atomic = ManagedAtomic(false)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.futureResult.whenFailure { _ in
            atomic.store(true, ordering: .relaxed)
        }
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )

        XCTAssertEqual(
            state.enqueue(task: .lobOperation(context)),
            .sendLOBOperation(context)
        )
        XCTAssertEqual(
            state.errorHappened(.uncleanShutdown),
            .closeConnectionAndCleanup(
                .init(
                    action: .fireChannelInactive,
                    tasks: [],
                    error: .uncleanShutdown,
                    read: false,
                    closePromise: nil
                )
            )
        )
        XCTAssertTrue(atomic.load(ordering: .relaxed))
    }

    func testFailLOBOperationOnError() {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.fail(StatementContext.TestComplete())
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )
        let error =
            OracleBackendMessage
            .BackendError(number: 1, isWarning: false, batchErrors: [])

        XCTAssertEqual(
            state.enqueue(task: .lobOperation(context)),
            .sendLOBOperation(context)
        )
        XCTAssertEqual(
            state.backendErrorReceived(error),
            .failLOBOperation(promise, with: .server(error))
        )
    }

    func testFailLOBOperationWhileClosing() {
        var state = ConnectionStateMachine(.closing)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.fail(StatementContext.TestComplete())
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )
        let error =
            OracleBackendMessage
            .BackendError(number: 1, isWarning: false, batchErrors: [])

        XCTAssertEqual(
            state.enqueue(task: .lobOperation(context)),
            .failLOBOperation(promise, with: .server(error))
        )
    }

    func testResendLOBOperation() {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.fail(StatementContext.TestComplete())
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )

        XCTAssertEqual(
            state.enqueue(task: .lobOperation(context)),
            .sendLOBOperation(context)
        )
        XCTAssertEqual(state.resendReceived(), .sendLOBOperation(context))
    }
}
