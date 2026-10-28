/// Opt in when a Player backend supplies a continuous playback clock and track
/// events for Flutter-rendered external subtitles. Other custom players may
/// continue driving CinemaExternalSubtitleState.updatePosition themselves.
abstract interface class CinemaSubtitlePlaybackClock {}
