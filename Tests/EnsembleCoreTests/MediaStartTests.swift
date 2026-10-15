import Testing
@testable import EnsembleCore

/// Each test feeds a sequence of Now Playing states and expects which of them are starts.
struct MediaStartTests {
    let own = "com.lacrearthur.ensemble"

    func starts(_ states: [(Bool, String?)]) -> [Bool] {
        var d = MediaStart(own: own)
        return states.map { d.feed(NowPlaying(playing: $0.0, app: $0.1)) }
    }

    @Test func pausedMusicThatPlaysAgainStarts() {
        #expect(starts([(false, "com.spotify.client"), (true, "com.spotify.client")]) == [false, true])
    }

    @Test func musicAlreadyPlayingWhenTheWatchBeginsDoesNotStart() {
        // This Mac just lost sharing and its app ignored the pause: it must not take sharing back.
        #expect(starts([(true, "com.spotify.client")]) == [false])
    }

    @Test func playingOnDoesNotStartAgain() {
        #expect(starts([(false, "com.spotify.client"), (true, "com.spotify.client"), (true, "com.spotify.client")]) == [false, true, false])
    }

    @Test func ensembleItselfPlayingNeverStarts() {
        // While this Mac plays the other Mac's sound, Ensemble is its now-playing app.
        #expect(starts([(false, nil), (true, own)]) == [false, false])
    }

    @Test func anotherAppStartingWhileEnsembleShowsPlayingStarts() {
        #expect(starts([(true, own), (true, "com.google.Chrome")]) == [false, true])
    }

    @Test func aSecondAppStartingWhileTheFirstPlaysStarts() {
        #expect(starts([(true, "com.apple.Music"), (true, "com.google.Chrome")]) == [false, true])
    }

    @Test func pausingIsNotAStart() {
        #expect(starts([(false, "com.apple.Music"), (true, "com.apple.Music"), (false, "com.apple.Music")]) == [false, true, false])
    }

    @Test func aPausedAppBecomingTheShownOneIsNotAStart() {
        // When a player quits, Control Center shows the last paused one again (seen live).
        #expect(starts([(true, "com.google.Chrome"), (false, "com.apple.Music")]) == [false, false])
    }
}
