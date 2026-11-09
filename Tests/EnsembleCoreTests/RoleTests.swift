import Testing
@testable import EnsembleCore

struct RoleTests {
    func role(on: Bool = false, headphones: Bool = false, peerOn: Bool = false, stream: String = "") -> Role {
        Role(on: on, headphones: headphones, peerOn: peerOn, peerStream: stream)
    }

    @Test func switchedOnShares() { #expect(role(on: true) == .sharing) }
    /// Both switched on: this Mac shares until `yields` turns its switch off.
    @Test func switchedOnSharesWhileTheOtherMacIsOnToo() { #expect(role(on: true, peerOn: true, stream: "s") == .sharing) }
    @Test func nobodySharingIsOff() { #expect(role() == .off) }
    @Test func headphonesAloneAreJustOff() { #expect(role(headphones: true) == .off) }
    @Test func headphonesWhileSharingAreStandby() { #expect(role(on: true, headphones: true) == .standby) }
    @Test func headphonesWhileTheOtherMacSharesAreStandby() { #expect(role(headphones: true, peerOn: true, stream: "s") == .standby) }
    @Test func theOtherMacSharingIsReceived() { #expect(role(peerOn: true, stream: "s") == .receiving(stream: "s")) }
    @Test func theOtherMacSharingSilentlyIsReceivingNoStream() { #expect(role(peerOn: true) == .receiving(stream: "")) }

    @Test func theLaterSwitchWins() {
        #expect(Role.yields(since: 1, id: "a", to: 2, "b"))
        #expect(!Role.yields(since: 2, id: "a", to: 1, "b"))
    }

    @Test func equalTimesGoToTheLargerID() {
        #expect(Role.yields(since: 1, id: "a", to: 1, "b"))
        #expect(!Role.yields(since: 1, id: "b", to: 1, "a"))
    }
}
