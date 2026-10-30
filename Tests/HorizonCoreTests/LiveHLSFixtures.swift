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
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Camera audio",DEFAULT=YES,URI="audio/index.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1450000,AVERAGE-BANDWIDTH=1300000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio"
    720p/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2850000,AVERAGE-BANDWIDTH=2600000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio"
    1080p/index.m3u8
    """

    static let child = """
    #EXTM3U
    #EXT-X-VERSION:9
    #EXT-X-TARGETDURATION:2
    #EXT-X-PART-INF:PART-TARGET=0.333
    #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0
    #EXT-X-MAP:URI="init.mp4"
    #EXT-X-PART:DURATION=0.333,URI="part-1.m4s",INDEPENDENT=YES
    #EXTINF:2.0,
    segment-1.m4s
    #EXT-X-PRELOAD-HINT:TYPE=PART,URI="part-2.m4s"
    #EXT-X-RENDITION-REPORT:URI="../1080p/index.m3u8",LAST-MSN=1,LAST-PART=1
    """

    static let safeChild = child.replacingOccurrences(
        of: "../1080p/index.m3u8", with: "/base/api/front/live/hls/1080p/index.m3u8"
    )
}
