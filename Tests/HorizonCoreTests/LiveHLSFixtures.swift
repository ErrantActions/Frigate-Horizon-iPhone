import Foundation

enum LiveHLSFixtures {
    static let status = Data("""
    {"version":1,"protocol":"ll-hls","enabled":true,"available":true,
     "playlist":"front/live/hls/master.m3u8",
     "renditions":[{"height":720,"bitrate":1200},{"height":1080,"bitrate":2500}]}
    """.utf8)

    static let master = """
    #EXTM3U
    #EXT-X-VERSION:9
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Camera audio",DEFAULT=YES,URI="720p/audio.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1876000,AVERAGE-BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",FRAME-RATE=15.000,AUDIO="audio"
    720p/primary.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=3631000,AVERAGE-BANDWIDTH=2500000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio"
    1080p/primary.m3u8
    """

    static let child = """
    #EXTM3U
    #EXT-X-VERSION:9
    #EXT-X-TARGETDURATION:2
    #EXT-X-PART-INF:PART-TARGET=0.333
    #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0
    #EXT-X-MAP:URI="init.mp4"
    #EXT-X-PART:DURATION=0.333,URI="part-1.mp4",INDEPENDENT=YES
    #EXTINF:2.0,
    segment-1.mp4
    #EXT-X-PRELOAD-HINT:TYPE=PART,URI="part-2.mp4"
    #EXT-X-RENDITION-REPORT:URI="audio.m3u8",LAST-MSN=1,LAST-PART=1
    """

    static let safeChild = child
}
