//
//  AudioPlayer+PlayerEvent.swift
//  AudioPlayer
//
//  Created by Kevin DELANNOY on 03/04/16.
//  Copyright © 2016 Kevin Delannoy. All rights reserved.
//

extension AudioPlayer {

    /// Boolean value indicating whether the player should resume playing (after buffering)
    var shouldResumePlaying: Bool {
        return !state.isPaused &&
            !(stateWhenConnectionLost?.isPaused ?? false) &&
            !(stateBeforeBuffering?.isPaused ?? false)
    }

    /// Handles player events.
    ///
    /// - Parameters:
    ///   - producer: The event producer that generated the player event.
    ///   - event: The player event.
    func handlePlayerEvent(from producer: EventProducer, with event: PlayerEventProducer.PlayerEvent) {
        switch event {
        case .endedPlaying(let error):
            if let error = error {
                state = .failed(.foundationError(error))
            } else {
                nextOrStop()
            }

        case .interruptionBegan where state.isPlaying || state.isBuffering:
            //We pause the player when an interruption is detected
            backgroundHandler.beginBackgroundTask()
            pausedForInterruption = true
            pause()

        case .interruptionEnded(let shouldResume) where pausedForInterruption:
            if resumeAfterInterruption && shouldResume {
                resume()
            }
            pausedForInterruption = false
            backgroundHandler.endBackgroundTask()

        case .loadedDuration(let time):
            if let currentItem = currentItem, let time = time.ap_timeIntervalValue {
                updateNowPlayingInfoCenter()
                delegate?.audioPlayer(self, didFindDuration: time, for: currentItem)
            }

        case .loadedMetadata(let metadata):
            if let currentItem = currentItem, !metadata.isEmpty {
                currentItem.parseMetadata(metadata)
                delegate?.audioPlayer(self, didUpdateEmptyMetadataOn: currentItem, withData: metadata)
            }

        case .loadedMoreRange:
            if let currentItem = currentItem, let currentItemLoadedRange = currentItemLoadedRange {
                delegate?.audioPlayer(self, didLoad: currentItemLoadedRange, for: currentItem)

                if bufferingStrategy == .playWhenPreferredBufferDurationFull && state == .buffering,
                    let currentItemLoadedAhead = currentItemLoadedAhead,
                    currentItemLoadedAhead.isNormal,
                    currentItemLoadedAhead >= self.preferredBufferDurationBeforePlayback {
                        playImmediately()
                }
            }

        case .loadedSeekableTimeRanges(let ranges):
            if let currentItem = currentItem {
                let timeRanges = ranges.flatMap { range -> TimeRange? in
                    if let earliest = range.start.ap_timeIntervalValue, let latest = range.end.ap_timeIntervalValue {
                        return (earliest, latest)
                    } else {
                        return nil
                    }
                }

                delegate?.audioPlayer(self, didUpdateSeekableTimeRanges: timeRanges, for: currentItem)

                // For live HLS streams there is no duration metadata
                // So we should update duration property with seekable time ranges
                if player?.currentItem?.duration.ap_timeIntervalValue == nil, let duration = currentItemDuration {
                    delegate?.audioPlayer(self, didFindDuration: duration, for: currentItem)
                }

                updateNowPlayingInfoCenter()
            }

        case .progressed(let time):
            if let currentItemProgression = time.ap_timeIntervalValue, let item = player?.currentItem,
                item.status == .readyToPlay {
                //This fixes the behavior where sometimes the `playbackLikelyToKeepUp` isn't
                //changed even though it's playing (happens mostly at the first play though).
                if state.isBuffering || state.isPaused {
                    if shouldResumePlaying {
                        state = .playing
                        player?.rate = rate
                    } else {
                        player?.rate = 0
                        state = .paused
                    }
                    backgroundHandler.endBackgroundTask()
                }

                //Then we can call the didUpdateProgressionTo: delegate method
                let itemDuration = currentItemDuration ?? 0
                let percentage = (itemDuration > 0 ? Float(currentItemProgression / itemDuration) * 100 : 0)
                delegate?.audioPlayer(self, didUpdateProgressionTo: currentItemProgression, percentageRead: percentage)
            }

        case .readyToPlay:
            //There is enough data in the buffer
            if shouldResumePlaying {
                state = .playing
                player?.rate = rate
            } else {
                player?.rate = 0
                state = .paused
            }

            //TODO: where to start?
            retryEventProducer.stopProducingEvents()
            backgroundHandler.endBackgroundTask()

        case .routeChanged:
            //In some route changes, the player pause automatically
            //TODO: there should be a check if state == playing
            if let player = player, player.rate == 0 {
                state = .paused
            }

        case .sessionMessedUp:
            #if os(iOS) || os(tvOS)
                //We reenable the audio session directly in case we're in background
                setAudioSession(active: true)

                //Aaaaand we: restart playing/go to next
                state = .stopped
                qualityAdjustmentEventProducer.interruptionCount += 1
                retryOrPlayNext()
            #endif

        case .startedBuffering:
            //The buffer is empty and player is loading
            if case .playing = state, !qualityIsBeingChanged {
                qualityAdjustmentEventProducer.interruptionCount += 1
            }

            stateBeforeBuffering = state
            if reachability.isReachable() || (currentItem?.soundURLs[currentQuality]?.ap_isOfflineURL ?? false) {
                state = .buffering
            } else {
                state = .waitingForConnection
            }
            backgroundHandler.beginBackgroundTask()

        case .interruptionBegan: ()
        case .interruptionEnded: ()
        }
    }
}
