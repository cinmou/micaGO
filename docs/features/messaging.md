# 消息、发送与会话

## 消息身份

一条消息属于具体聊天路线。使用聊天 GUID 和服务端消息 GUID 定位它；同一联系人下的多个电话或邮箱不能省略路线。

客户端发送前会建立临时气泡。临时 GUID 和展示用 key 不能充当跨设备消息身份。隐藏单条消息时，持久 key 为 `chatGuid + U+001F + messageGuid`；Windows 使用 `Message.ServerKey`。

## 历史与增量

聊天列表来自 `/api/chats`。历史使用 `/api/messages/history`，可查询多个路线，服务端按 `(date_created, source_rowid)` 返回统一分页游标。不要恢复客户端逐路线并行取历史后再拼接的做法。

`/api/messages/delta` 用于追赶新变化，不是向上翻历史的接口。隐藏、已读或联系人合并不能改变消息摄取和历史分页游标。

## 发送状态

客户端先显示乐观气泡，再上传或提交文本。服务端通过 Messages 发送，随后从 `chat.db` 查找确认记录。

明确拒绝可以显示失败并由用户重试。HTTP 超时、202 `send_confirmation_timeout` 或上传中断可能仍已发出，必须保留“等待确认”的可能性，不能自动重发。

`send:match` 带具体 `tempGuid` 时只确认对应发送；delta 兜底匹配需要逐条消费候选，不能把一条服务端消息确认到多个临时气泡。附件匹配含名称、大小和时间范围，存在歧义时不猜。

本地气泡确认后应保留展示身份和位置，并采用服务端确认的媒体内容。后到的旧缓存快照不能重新插入临时气泡，也不能把消息带到另一个聊天中。

SMS 发送需要服务端允许；不能根据会话最新预览来自哪个账号来推断可发送路线。编辑、撤回和删除使用可选 IMCore 能力检测，无法支持时给出真实状态。发送回应、输入状态和群组管理不属于现有发送接口。定时发送尚未实现，旧路线图不代表当前承诺。

## 显示

消息解析区分正文、附件、回应、回复、系统事件与撤回。空正文的回应仍然需要同步；不能把所有空文本行当无效记录丢弃。自定义 Tapback 使用 `associatedMessageEmoji`。

分组、时间分隔、群聊发送者和送达脚注由各端的消息展示模型处理。不要在页面、气泡和同步层各写一套不同的分组规则。空对象占位字符不能直接显示成正文。

## 联系人合并

联系人名字不是唯一身份。Flutter 使用本机联系人，Windows 使用导入的 vCard；它们不会天然共享同一份联系人 ID。

一对一会话可以按稳定联系人身份合并。发送时仍要保留明确的路线；群聊不参与联系人合并。Windows 允许在详情中显式关联旧的分散联系人账号，重新导入不能抹掉这些关联。

两端的合并入口和路线范围并非完全相同。当前没有已经批准的跨端统一选择流程；后续修改应核对两端实现，不把旧建议直接当成产品要求。

## 隐藏、屏蔽和本地设置

- 隐藏聊天：跨设备同步，聊天继续摄取，但不出现在列表且不通知。
- 隐藏消息：跨设备同步单条可见性，不删除 Messages 原始记录。
- Sync Control 屏蔽：控制后续同步或推送，不自动清除已经同步的数据。
- 置顶、静音、主题和联系人匹配：按各端现有设置处理，不假定所有设置都跨设备同步。

聊天和消息隐藏使用带版本检查、mutation ID（操作 ID）的服务端批量更新。客户端保存待同步操作，冲突时提供明确选择。清缓存要保留队列，设置备份要排除队列；旧本地隐藏记录不能无提示覆盖服务端。

## 实现与验证

- 服务端：[httpapi](../../MicaGoServer/micago-server/internal/httpapi)、[relaydb](../../MicaGoServer/micago-server/internal/relaydb)。
- Flutter：[thread_controller_reconciliation_test.dart](../../MicaGoFlutterClient/test/thread_controller_reconciliation_test.dart)、[late_send_confirmation_test.dart](../../MicaGoFlutterClient/test/late_send_confirmation_test.dart)、[message_visibility_thread_test.dart](../../MicaGoFlutterClient/test/message_visibility_thread_test.dart)。
- Windows：[MessageSemantics.cs](../../MicaGoWindowsClient/src/micaGO.Core/Models/MessageSemantics.cs)、[LateSendConfirmationTests.cs](../../MicaGoWindowsClient/tests/micaGO.Core.ContractTests/LateSendConfirmationTests.cs)、[ContactConversationTests.cs](../../MicaGoWindowsClient/tests/micaGO.Core.ContractTests/ContactConversationTests.cs)。
