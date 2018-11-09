import NIO
import Dispatch
@testable import Redis
import XCTest

extension RedisClient {
    /// Creates a test event loop and Redis client.
    static func makeTest() throws -> RedisClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let password = Environment.get("REDIS_PASSWORD")
        let client = try RedisClient.connect(
            hostname: "localhost",
            port: 6379,
            password: password,
            on: group
        ) { error in
            XCTFail("\(error)")
        }.wait()
        return client
    }
}

class RedisTests: XCTestCase {
    let defaultTimeout = 2.0
    func testCRUD() throws {
        let redis = try RedisClient.makeTest()
        defer { redis.close() }
        try redis.set("hello", to: "world").wait()
        let get = try redis.get("hello", as: String.self).wait()
        XCTAssertEqual(get, "world")
        try redis.delete("hello").wait()
        XCTAssertNil(try redis.get("hello", as: String.self).wait())
    }

    func testPubSubSingleChannel() throws {
        let futureExpectation = expectation(description: "Subscriber should receive message")

        let redisSubscriber = try RedisClient.makeTest()
        let redisPublisher = try RedisClient.makeTest()
        defer {
            redisPublisher.close()
            redisSubscriber.close()
        }

        let channel1 = "channel1"
        let channel2 = "channel2"

        let expectedChannel1Msg = "Stuff and things"
        _ = try redisSubscriber.subscribe(Set([channel1])) { channelData in
            if channelData.data.string == expectedChannel1Msg {
                futureExpectation.fulfill()
            }
        }.catch { _ in
            XCTFail("this should not throw an error")
        }

        _ = try redisPublisher.publish("Stuff and things", to: channel1).wait()
        _ = try redisPublisher.publish("Stuff and things 3", to: channel2).wait()
        waitForExpectations(timeout: defaultTimeout)
    }

    func testPubSubMultiChannel() throws {
        let expectedChannel1Msg = "Stuff and things"
        let expectedChannel2Msg = "Stuff and things 3"
        let futureExpectation1 = expectation(description: "Subscriber should receive message \(expectedChannel1Msg)")
        let futureExpectation2 = expectation(description: "Subscriber should receive message \(expectedChannel2Msg)")
        let redisSubscriber = try RedisClient.makeTest()
        let redisPublisher = try RedisClient.makeTest()
        defer {
            redisPublisher.close()
            redisSubscriber.close()
        }

        let channel1 = "channel/1"
        let channel2 = "channel/2"

        _ = try redisSubscriber.subscribe(Set([channel1, channel2])) { channelData in
            if channelData.data.string == expectedChannel1Msg {
                futureExpectation1.fulfill()
            } else if channelData.data.string == expectedChannel2Msg {
                futureExpectation2.fulfill()
            }
        }.catch { _ in
            XCTFail("this should not throw an error")
        }
        _ = try redisPublisher.publish("Stuff and things", to: channel1).wait()
        _ = try redisPublisher.publish("Stuff and things 3", to: channel2).wait()
        waitForExpectations(timeout: defaultTimeout)
    }

    func testStruct() throws {
        struct Hello: Codable {
            var message: String
            var array: [Int]
            var dict: [String: Bool]
        }
        let hello = Hello(message: "world", array: [1, 2, 3], dict: ["yes": true, "false": false])
        let redis = try RedisClient.makeTest()
        defer { redis.close() }
        try redis.jsonSet("hello", to: hello).wait()
        let get = try redis.jsonGet("hello", as: Hello.self).wait()
        XCTAssertEqual(get?.message, "world")
        XCTAssertEqual(get?.array.first, 1)
        XCTAssertEqual(get?.array.last, 3)
        XCTAssertEqual(get?.dict["yes"], true)
        XCTAssertEqual(get?.dict["false"], false)
        try redis.delete("hello").wait()
    }

    func testStringCommands() throws {
        let redis = try RedisClient.makeTest()
        defer { redis.close() }

        let values = ["hello": RedisData(bulk: "world"), "hello2": RedisData(bulk: "world2")]
        try redis.mset(with: values).wait()
        let resp = try redis.mget(["hello", "hello2"]).wait()
        XCTAssertEqual(resp[0].string, "world")
        XCTAssertEqual(resp[1].string, "world2")
        _ = try redis.delete(["hello", "hello2"]).wait()

        let number = try redis.increment("number").wait()
        XCTAssertEqual(number, 1)
        let number2 = try redis.increment("number", by: 10).wait()
        XCTAssertEqual(number2, 11)
        let number3 = try redis.decrement("number", by: 10).wait()
        XCTAssertEqual(number3, 1)
        let number4 = try redis.decrement("number").wait()
        XCTAssertEqual(number4, 0)
        _ = try redis.delete(["number"]).wait()
    }
    
    
    func testHashCommands() throws {
        let redis = try RedisClient.makeTest()
        defer { redis.close() }
        
        // create hash value
        let hsetResponse = try redis.hset("hello", field: "world", to: RedisData(bulk: "whatever")).wait()
        XCTAssertEqual(hsetResponse, 1)
        
        // get all field names
        let hkeysResponse = try redis.hkeys("hello").wait()
        XCTAssertEqual(hkeysResponse.count, 1)
        XCTAssertEqual(hkeysResponse.first, "world")
        
        // update hash value
        let hsetResponse2 = try redis.hset("hello", field: "world", to: RedisData(bulk: "value")).wait()
        XCTAssertEqual(hsetResponse2, 0)
        
        // get hash value
        let hgetResponse = try redis.hget("hello", field: "world", as: String.self).wait()
        XCTAssertNotNil(hgetResponse)
        XCTAssertEqual(hgetResponse, "value")
        
        // delete hash value
        let hdelResponse = try redis.hdel("hello", fields: "not-existing-field").wait()
        XCTAssertEqual(hdelResponse, 0)
        let hdelResponse2 = try redis.hdel("hello", fields: "world").wait()
        XCTAssertEqual(hdelResponse2, 1)
        
        // get hash value
        let hgetResponse2 = try redis.hget("hello", field: "world", as: String.self).wait()
        XCTAssertNil(hgetResponse2)
    }
    
    

    func testListCommands() throws {
        let redis = try RedisClient.makeTest()
        defer { redis.close() }
        _ = try redis.command("FLUSHALL").wait()

        let lpushResp = try redis.lpush([RedisData(bulk: "hello")], into: "mylist").wait()
        XCTAssertEqual(lpushResp, 1)

        let rpushResp = try redis.rpush([RedisData(bulk: "hello1")], into: "mylist").wait()
        XCTAssertEqual(rpushResp, 2)

        let length = try redis.length(of: "mylist").wait()
        XCTAssertEqual(length, 2)

        let item = try redis.lIndex(list: "mylist", index: 0).wait()
        XCTAssertEqual(item.string, "hello")

        let items = try redis.lrange(list: "mylist", range: 0...1).wait()
        XCTAssertEqual(items.array?.count, 2)

        try redis.lSet(RedisData(bulk: "hello2"), at: 0, in: "mylist").wait()
        let item2 = try redis.lIndex(list: "mylist", index: 0).wait()
        XCTAssertEqual(item2.string, "hello2")

        let rpopResp = try redis.rPop("mylist").wait()
        XCTAssertEqual(rpopResp.string, "hello1")

        let rpoplpush = try redis.rpoplpush(source: "mylist", destination: "list2").wait()
        XCTAssertEqual(rpoplpush.string, "hello2")

        _ = try redis.delete(["mylist", "list2"]).wait()
    }

    func testExpire() throws {
        let redis = try RedisClient.makeTest()
        defer { redis.close() }
        _ = try redis.command("FLUSHALL").wait()

        try redis.set("foo", to: "bar").wait()
        XCTAssertEqual(try redis.get("foo", as: String.self).wait(), "bar")
        _ = try redis.expire("foo", after: 1).wait()
        sleep(2)
        XCTAssertEqual(try redis.get("foo", as: String.self).wait(), nil)
    }

    static let allTests = [
        ("testCRUD", testCRUD),
        ("testPubSubSingleChannel", testPubSubSingleChannel),
        ("testPubSubMultiChannel", testPubSubMultiChannel),
        ("testStruct", testStruct),
        ("testStringCommands", testStringCommands),
        ("testListCommands", testListCommands),
        ("testExpire", testExpire),
        ("testHashCommands", testHashCommands)
    ]
}
