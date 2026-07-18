# 代码结构

## 项目边界

```text
MicaGoWindowsClient/
├── src/
│   ├── micaGO.App/              WinUI 3 窗口、页面、控件和主题
│   ├── micaGO.Core/             无 UI 的连接与聊天领域模型
│   └── micaGO.Infrastructure/   HTTP、线路探测、凭据和配置存储
└── tests/
    └── micaGO.Core.ContractTests/
```

`micaGO.Core` 不引用 WinUI 或 Windows API，可独立测试。`micaGO.Infrastructure` 实现网络和 Windows 存储。`micaGO.App` 只负责生命周期和界面状态，不应自行拼接服务端 JSON。

## 启动流程

```text
MainWindow
  -> ConnectionPage
      -> ConnectionManager.TryRestoreAsync
          -> ConnectionStore 读取普通配置
          -> CredentialManager 读取 token
          -> EndpointSelector 探测 LAN/Public
          -> MicaGoApi
      -> ShellPage
          -> /api/chats
          -> /api/chats/{guid}/messages
          -> /api/chats/{guid}/send
```

应用级对象由 `AppServices.Current` 持有。当前只包含一个 `ConnectionManager`；窗口关闭时统一释放活动 `HttpClient`。

## 关键文件

- `Core/Connection/PairingPayloadParser.cs`：v1/v2/v3 配对解析和安全过滤
- `Core/Connection/EndpointUrls.cs`：REST/WS URL 标准化
- `Infrastructure/Connection/EndpointSelector.cs`：LAN 并行测速和 Public 回退
- `Infrastructure/Connection/ConnectionManager.cs`：恢复、激活和断开连接
- `Infrastructure/Storage/CredentialManagerSecretStore.cs`：Windows Credential Manager P/Invoke
- `Infrastructure/Storage/ConnectionStore.cs`：不含 token 的 JSON 配置
- `Infrastructure/Api/MicaGoApi.cs`：服务端 REST 映射
- `App/Views/ConnectionPage.xaml`：配对与恢复界面
- `App/Views/ShellPage.xaml`：双栏聊天界面
- `App/Controls/MessageBubble.xaml`：原生消息气泡

## UI 原则

布局以 Flutter Pad 的双栏实现为准：左侧会话列表，右侧内嵌聊天，不改成 Unigram 的导航结构。视觉上采用紧凑行高、轻分隔、清晰 hover/selected 状态、Fluent 图标和原生菜单。

Unigram 仅作为设计观察来源。不得复制它的 GPL XAML、ControlTemplate、图片、字体或源代码。所有 micaGO 控件需要保持原创实现。

## 下一阶段结构

后续不应把 WebSocket、SQLite 和页面状态直接堆进 `ShellPage.xaml.cs`。建议新增：

```text
Infrastructure/Realtime/MicaGoRealtimeClient.cs
Infrastructure/Storage/MicaGoDatabase.cs
Core/Sync/MessageDeltaCoordinator.cs
App/ViewModels/ShellViewModel.cs
App/ViewModels/ThreadViewModel.cs
```

消息进入统一管线后再更新 UI：REST history、WebSocket event 和 delta catch-up 都先按 message GUID 去重并写入 SQLite，然后由 ViewModel 发布有序集合。这样重连不会产生重复气泡。

