public enum LivePiPPlaybackPolicy {
    public static func mayKeepPlaying(
        accountAuthorized: Bool, cameraEnabled: Bool, hasStream: Bool,
        foreground: Bool, visible: Bool, active: Bool,
        pictureInPictureActive: Bool
    ) -> Bool {
        accountAuthorized && cameraEnabled && hasStream &&
            (pictureInPictureActive || (foreground && visible && active))
    }
}
