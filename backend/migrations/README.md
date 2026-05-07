# Schema Migrations

万象书屋后端 DB schema 版本化目录.

## 规则

- 每个 SQL 文件按 `001_xxx.sql`, `002_xxx.sql` 顺序命名
- 文件**不可删, 不可改** (生产已跑过的)
- 改 schema 都新建一个迁移文件, 不直接修改老的
- `db.js` 启动时自动按文件名顺序检查 `schema_migrations` 表, 跑没跑过的

## 创建迁移

```bash
# 1. 创建文件
touch migrations/00X_add_my_table.sql

# 2. 写 SQL (一定要 IF NOT EXISTS / IF NOT EXISTS 兼容老库)
CREATE TABLE IF NOT EXISTS my_table (...);

# 3. 启动 server, 自动执行
node server.js
# 看到 [migrations] applied 00X_add_my_table.sql
```

## 历史

- `001_baseline.sql`: 占位, 标记已存在的所有老表已就绪 (空操作)
- 后续版本按编号递增

## 紧急回滚

迁移**不支持自动回滚** — SQLite 不支持事务 DDL, 回滚靠"恢复备份" (`scripts/restore-backup.js`).

所以新迁移上线**必须先备份** (admin /api/admin/backup/now).
