# 已读与未读

## 两种状态分开保存

已读水位表示“这条路线读到哪个消息时间”。它只能向前，不能因为旧响应、历史加载或切换设备而倒退。

手动未读是另外的 `markedUnread` 标记。把会话标为未读不会把水位往回改。

状态按聊天路线保存。合并联系人只是把多条路线放在同一视图，不能把某个电话收到的消息误记到另一个邮箱上。

## 什么会推进已读水位

收到消息不会自动把别人的消息标为已读。打开并阅读会话，或执行“标为已读”，才推进对应路线的水位；应用处于后台、旧线程还留在导航栈中，都不算阅读。

自己发出的消息可以更新自己发送路线的已读状态，不能顺手清除同一联系人其他路线的未读。初次导入历史按客户端初始化规则处理，不能把全部旧历史变成新通知。

服务端用 `/api/read-state` 持久保存水位、手动未读和版本号。客户端先更新本地外观，再通过路线级版本检查提交；失败要保留重试或恢复显示，不能清掉之后才收到的新消息。

这里的“已读”是 micaGO 内部的跨设备状态，不代表向 Apple 发送 iMessage 已读回执。

## 角标

客户端优先依据 `hasUnread` 决定是否有未读。静音会话显示点；有可靠正数计数时显示数字，否则显示点。不要通过“收到一次事件就加一”的孤立计数替代缓存与水位计算。

合并会话汇总所有参与路线的状态。清某一条路线不等于清整个联系人。

## 通知里的“标为已读”

使用通知中实际包含的原始消息时间作截止点，不能用推送派发时间，也不能用点击操作时缓存里更新的最大时间。未知截止点不执行标读。

成功后只清理截止点以前的通知和预览。操作期间收到的新消息应留下。网络失败保持可重试；旧配对和已撤销凭据不能继续执行后台操作。

## 实现与验证

- 服务端：[read_state.go](../../MicaGoServer/micago-server/internal/httpapi/read_state.go)、[read_state_test.go](../../MicaGoServer/micago-server/internal/httpapi/read_state_test.go)。
- Flutter：[read_state_sync.dart](../../MicaGoFlutterClient/lib/core/network/read_state_sync.dart)、[read_state_sync_test.dart](../../MicaGoFlutterClient/test/read_state_sync_test.dart)、[notification_reply_test.dart](../../MicaGoFlutterClient/test/notification_reply_test.dart)。
- Windows：[ChatUnreadTests.cs](../../MicaGoWindowsClient/tests/micaGO.Core.ContractTests/ChatUnreadTests.cs)、[ReadStateSyncTests.cs](../../MicaGoWindowsClient/tests/micaGO.Core.ContractTests/ReadStateSyncTests.cs)。

实机至少检查：后台收消息、两设备交替阅读、手动未读冲突、合并路线，以及通知标读期间到达新消息。
