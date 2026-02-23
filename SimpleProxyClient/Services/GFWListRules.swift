import Foundation

nonisolated enum GFWListRules: Sendable {

    static let proxyDomains: Set<String> = [
        "google.com", "google.co.jp", "google.co.kr", "google.com.hk",
        "googleapis.com", "googleusercontent.com", "googlevideo.com",
        "gstatic.com", "ggpht.com", "googleadservices.com", "google-analytics.com",
        "youtube.com", "ytimg.com", "youtu.be", "yt.be",
        "facebook.com", "fbcdn.net", "fb.com", "fb.me",
        "instagram.com", "cdninstagram.com",
        "twitter.com", "twimg.com", "t.co", "x.com",
        "whatsapp.com", "whatsapp.net",
        "telegram.org", "t.me", "telegram.me", "telesco.pe",
        "reddit.com", "redd.it", "redditimg.com", "redditmedia.com",
        "wikipedia.org", "wikimedia.org", "wiktionary.org",
        "github.com", "githubusercontent.com", "github.io", "githubassets.com",
        "stackoverflow.com", "stackexchange.com",
        "medium.com",
        "nytimes.com", "wsj.com", "bbc.com", "bbc.co.uk",
        "reuters.com", "bloomberg.com", "ft.com",
        "netflix.com", "nflxvideo.net", "nflximg.net",
        "spotify.com", "scdn.co",
        "twitch.tv", "ttvnw.net",
        "discord.com", "discordapp.com", "discord.gg",
        "signal.org", "signal.chat",
        "line.me", "naver.jp",
        "dropbox.com", "dropboxusercontent.com",
        "amazonaws.com", "cloudfront.net",
        "openai.com", "chatgpt.com", "oaiusercontent.com",
        "anthropic.com", "claude.ai",
        "docker.com", "docker.io",
        "npmjs.com", "npmjs.org",
        "pypi.org", "pythonhosted.org",
        "wordpress.com", "wp.com",
        "tumblr.com",
        "pinterest.com",
        "flickr.com",
        "vimeo.com",
        "soundcloud.com",
        "archive.org",
        "duckduckgo.com",
        "protonmail.com", "proton.me",
        "mega.nz", "mega.io",
        "notion.so", "notion.site",
        "slack.com", "slack-edge.com",
        "zoom.us", "zoom.com",
        "akamaized.net", "akamai.net",
        "cloudflare.com", "cloudflare-dns.com",
        "steampowered.com", "steamcommunity.com",
        "pixiv.net",
        "quora.com",
        "hulu.com",
        "theguardian.com",
        "cnn.com",
    ]

    static let directDomains: Set<String> = [
        "baidu.com", "bdstatic.com", "bdimg.com", "baidubce.com",
        "qq.com", "gtimg.com", "qpic.cn", "qcloud.com",
        "weixin.qq.com", "wechat.com", "wx.qq.com",
        "taobao.com", "tmall.com", "alicdn.com", "aliyun.com", "alibaba.com", "alipay.com",
        "jd.com", "360buyimg.com", "jdcloud.com",
        "163.com", "126.com", "netease.com", "ydstatic.com",
        "sina.com.cn", "weibo.com", "sinaimg.cn",
        "sohu.com", "sogou.com", "sogo.com",
        "bilibili.com", "hdslb.com", "bilivideo.com", "b23.tv",
        "douyin.com", "tiktokv.com", "bytedance.com", "byteimg.com", "pstatp.com",
        "zhihu.com", "zhimg.com",
        "douban.com",
        "meituan.com", "dianping.com",
        "ctrip.com", "trip.com",
        "pinduoduo.com",
        "xiaomi.com", "mi.com", "miui.com",
        "huawei.com", "vmall.com",
        "csdn.net",
        "cnblogs.com",
        "jianshu.com",
        "toutiao.com",
        "iqiyi.com", "qiyi.com",
        "youku.com", "tudou.com",
        "kuaishou.com",
        "58.com", "ganji.com",
        "ele.me",
        "didi.com",
    ]

    static func shouldProxy(domain: String) -> Bool {
        let lowered = domain.lowercased()

        if lowered.hasSuffix(".cn") || lowered.hasSuffix(".com.cn") {
            return false
        }

        if matchesDomain(lowered, in: directDomains) { return false }
        if matchesDomain(lowered, in: proxyDomains) { return true }

        return true
    }

    private static func matchesDomain(_ domain: String, in domainSet: Set<String>) -> Bool {
        if domainSet.contains(domain) { return true }
        let parts = domain.split(separator: ".")
        for i in 1..<parts.count {
            let suffix = parts[i...].joined(separator: ".")
            if domainSet.contains(suffix) { return true }
        }
        return false
    }
}
