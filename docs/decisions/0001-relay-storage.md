# 0001：保留 relay.db

状态：现行。整理日期：2026-10-21。

## 背景与选择

Messages 使用 Apple 自己的数据库结构。micaGO 只读 `chat.db`，把需要的数据同步到自己的 `relay.db`，客户端 API 从这里读取。

已有说明明确选择保留独立缓存，而不是让每个 API 直接依赖 Messages 查询。它同时保存配对、偏好、已读和同步进度等 Apple 数据库不负责的状态。

## 代价

消息数据会有缓存副本，需要同步、迁移、去重和容量管理。缓存可重建不等于整个数据库可删除；重置整库会影响配对和用户状态。

按时间补查不能推进按 ROWID 排序的主摄取游标，否则可能跳过消息。

## 替代方案

直接查询 `chat.db` 少一份消息缓存，但客户端接口会更紧耦合 Apple schema，也不能替代 micaGO 自己的持久状态。这是当前实现保留 relay 的理由，不代表所有历史方案都已完整记录。

证据：[relaydb](../../MicaGoServer/micago-server/internal/relaydb)、[app.go](../../MicaGoServer/micago-server/internal/app/app.go)。
