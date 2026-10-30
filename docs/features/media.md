# 附件、播放与缓存

## 三类文件

原始附件属于 Mac Messages。服务端从数据库读取附件索引，经已鉴权 API 提供内容；客户端不能凭一个任意磁盘路径要求服务端读文件。

服务端预览与转码文件是派生缓存。客户端另有下载缓存，用于聊天显示和播放。清这些缓存不应删除原始附件、配对信息或待同步操作。

## 发送与确认

图片、文件和语音复用发送管线。客户端可以先显示本地预览，但确认后必须使用服务端对应的字节；不能把本地图片塞进服务端媒体缓存 key，导致错误内容长期命中。

多附件发送先建立各自的展示记录，再上传。上传进度更新原气泡，确认后保留展示身份。发送结果不确定时等待确认，不自动再上传一遍。

语音转换成功后应清理未提交的中间文件。清理失败和历史文件处理不能靠批量删除 Messages 目录来解决。

## 显示与播放

图片从本地预览切到服务端版本时保持同一个宽高比框架。不要通过额外淡入、尺寸动画或临时外层控件 让气泡跳动。

贴纸、关联贴纸、语音、位置卡片、链接预览和普通文件分开识别。看不到正文不等于没有内容。Windows 和 Flutter 使用各自的展示层，但保留相同的服务端附件身份。

Flutter 原生音视频先通过已鉴权、按配对证书策略校验的 API 下载，再交给播放器，避免播放器另走一条不带鉴权或不校验证书的请求。

Mac 的图片预览和视频转码依赖系统工具；不保证任意编码都能转换成功。服务端缓存对转换任务做串行保护，写完后原子发布，避免读到半成品。派生媒体缓存有容量和过期清理，具体上限以实现为准。

Flutter 媒体缓存使用 48 MiB 内存 LRU 和 256 MiB 磁盘缓存。磁盘文件读取后更新使用时间，30 天未使用或超过容量时淘汰；启动和写入后执行清理，超过 1 小时的未完成 `.part` 文件也会清除。缩略图、显示预览和原图使用不同 key，待发送的本地附件不进入磁盘淘汰范围。

Windows 气泡缩略图使用有上限的内存 LRU 和解码尺寸。详情页采用独立的小预览；不能一次解码整段历史的所有原图。

## 实现与验证

- 服务端：[附件和媒体处理](../../MicaGoServer/micago-server/internal/httpapi)、[media_cache_test.go](../../MicaGoServer/micago-server/internal/httpapi/media_cache_test.go)。
- Flutter：[media_cache.dart](../../MicaGoFlutterClient/lib/core/storage/media_cache.dart)、[media_history_transport_test.dart](../../MicaGoFlutterClient/test/media_history_transport_test.dart)、[chat_layout_stability_test.dart](../../MicaGoFlutterClient/test/chat_layout_stability_test.dart)。
- 发送确认规则见[消息](messaging.md)，Windows 细节见[平台说明](../platforms/windows.md)。

验证时分别检查首次加载、缓存命中、上传确认、横竖图切换、转换失败和缓存淘汰。自动测试不能证明所有系统播放器和实际附件格式都正常。
