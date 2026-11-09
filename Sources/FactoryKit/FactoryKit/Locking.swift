//
// Locking.swift
//  
// GitHub Repo and Documentation: https://github.com/hmlongco/Factory
//
// Copyright © 2022-2025 Michael Long. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

// MARK: - Locking

/// A lock that can run a closure while it holds the lock.
internal protocol Locking: AnyObject {
    func lock()
    func unlock()
}

extension Locking {
    @inlinable @inline(__always) func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock(); defer { unlock() }
        return try body()
    }
}

/// Master recursive lock
nonisolated(unsafe) internal var globalRecursiveLock = RecursiveLock()

/// Custom recursive lock
internal final class RecursiveLock: Locking {

    init() {
        let mutexAttr = UnsafeMutablePointer<pthread_mutexattr_t>.allocate(capacity: 1)
        pthread_mutexattr_init(mutexAttr)
        pthread_mutexattr_settype(mutexAttr, Int32(PTHREAD_MUTEX_RECURSIVE))
        mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(mutex, mutexAttr)
        pthread_mutexattr_destroy(mutexAttr)
        mutexAttr.deallocate()
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    @inlinable @inline(__always) func lock() {
        pthread_mutex_lock(mutex)
    }

    @inlinable @inline(__always) func unlock() {
        pthread_mutex_unlock(mutex)
    }

    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

}

/// Master variable spin lock
internal let globalVariableLock = CrossPlatformLock.make()

#if os(macOS) || os(iOS) || os(watchOS)
/// Custom lock using os_unfair_lock on Apple platforms.
///
/// The lock lives in the object's own allocation, after `locks`, through `ManagedBufferPointer`: one allocation,
/// at an address that never moves. `withUnsafeMutablePointer(to: &storedVar)` would be a write access to the
/// stored property, which two threads locking at once overlap, and gives no stable address.
internal final class CrossPlatformLock: Locking, @unchecked Sendable {

    private typealias Buffer = ManagedBufferPointer<Int, os_unfair_lock>

    /// A new lock, counted as taken once.
    internal static func make() -> CrossPlatformLock {
        let buffer = Buffer(bufferClass: CrossPlatformLock.self, minimumCapacity: 1) { _, _ in 1 }
        buffer.withUnsafeMutablePointerToElements { $0.initialize(to: os_unfair_lock()) }
        return unsafeDowncast(buffer.buffer, to: CrossPlatformLock.self)
    }

    deinit {
        buffer.withUnsafeMutablePointers { header, lock in
            lock.deinitialize(count: 1)
            header.deinitialize(count: 1)
        }
    }

    internal var locks: Int {
        get { buffer.header }
        set { buffer.withUnsafeMutablePointerToHeader { $0.pointee = newValue } }
    }

    @inlinable @inline(__always) func lock() {
        buffer.withUnsafeMutablePointerToElements { os_unfair_lock_lock($0) }
    }

    @inlinable @inline(__always) func unlock() {
        buffer.withUnsafeMutablePointerToElements { os_unfair_lock_unlock($0) }
    }

    @usableFromInline internal var buffer: ManagedBufferPointer<Int, os_unfair_lock> {
        ManagedBufferPointer(unsafeBufferObject: self)
    }

}
#else
/// Custom lock compatible with Linux using pthread_mutex.
internal final class CrossPlatformLock: Locking, @unchecked Sendable {

    internal var locks = 1

    /// A new lock, counted as taken once.
    internal static func make() -> CrossPlatformLock {
        CrossPlatformLock()
    }

    private init() {
        mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        let attributes = UnsafeMutablePointer<pthread_mutexattr_t>.allocate(capacity: 1)
        pthread_mutexattr_init(attributes)
        pthread_mutexattr_settype(attributes, Int32(PTHREAD_MUTEX_NORMAL))
        pthread_mutex_init(mutex, attributes)
        pthread_mutexattr_destroy(attributes)
        attributes.deallocate()
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    @inlinable @inline(__always) func lock() {
        pthread_mutex_lock(mutex)
    }

    @inlinable @inline(__always) func unlock() {
        pthread_mutex_unlock(mutex)
    }

    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
}
#endif

// MARK: - ReadWriteLock

/// Readers-writer lock: multiple concurrent readers, exclusive writers.
internal final class ReadWriteLock: @unchecked Sendable {

    init() {
        rwlock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(rwlock, nil)
    }

    deinit {
        pthread_rwlock_destroy(rwlock)
        rwlock.deallocate()
    }

    @inlinable @inline(__always) func readLock() {
        pthread_rwlock_rdlock(rwlock)
    }

    @inlinable @inline(__always) func writeLock() {
        pthread_rwlock_wrlock(rwlock)
    }

    @inlinable @inline(__always) func unlock() {
        pthread_rwlock_unlock(rwlock)
    }

    @inlinable @inline(__always) func withReadLock<T>(_ body: () -> T) -> T {
        readLock(); defer { unlock() }
        return body()
    }

    @inlinable @inline(__always) func withWriteLock<T>(_ body: () -> T) -> T {
        writeLock(); defer { unlock() }
        return body()
    }

    private let rwlock: UnsafeMutablePointer<pthread_rwlock_t>

}
