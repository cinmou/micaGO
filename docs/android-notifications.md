# Android 消息通知（0.88）

通知继续通过 flutter_local_notifications 的 MessagingStyle / Person / RemoteInput 显示。`micago_conversations` 只接 Android 的长期会话快捷方式、定向打开及按时间清理通知，前台和后台 Flutter 引擎均自动注册；传输、凭据与消息操作统一留在 Dart。

Android 11 起，会话通知关联已发布的 long-lived shortcut；头像来自本地联系人或用户设置，群聊区分会话头像和每位发送者。没有照片时交给系统回退。Android 7–10 保留系统消息通知及操作。具体通知栏布局由系统和 OEM 决定，不自绘通知。通知权限、FCM 和保活的现有开关保持不变，FCM 仍是可选配置。

“回复”发送普通新消息。发送不确定时提示等待确认，不自动重发。“标为已读”只提交当前通知包含的原始消息时间，不使用推送派发时间或缓存里后来到达的消息；服务端确认后更新本地水位。网络失败保留通知供重试。旧配对、无截止时间、已被拒绝的凭据均不能执行已读操作。服务端的 route-scoped CAS 保留手动未读冲突保护。

预览缓冲使用现有 SQLite 的事务更新，按设备与会话区分，限制每会话 6 行、总计 100 会话；群聊按发送者身份保留头像。操作完成时只删截止时间以前的预览，Android 在主线程检查当前通知的消息时间后决定是否取消，因此不会吞掉操作期间更新的新通知。跨设备读水位同步也使用这一清理路径。解绑/凭据撤销会清除原生通知与本应用的会话快捷方式。

参考：[Android People and conversations](https://developer.android.com/develop/ui/views/notifications/conversations)、[Android 通知操作](https://developer.android.com/develop/ui/compose/notifications/create-notification)、[flutter_local_notifications 快捷方式问题与示例](https://github.com/MaikuB/flutter_local_notifications/issues/2302)。复用现有通知插件与 AndroidX ShortcutManagerCompat，不实现第二套通知渲染器。

自动验证覆盖通知参数、同名发送者头像隔离、原始时间边界、并发缓冲、设备隔离、离线与 401、普通回复/不确定发送。设备验收还需在 Android 7–10 / 11+ 的实际系统通知栏确认头像、展开样式、长按会话菜单、锁屏回复、冷启动定位和标读后另一客户端状态；编译及 Dart 测试不能代替这些检查。
