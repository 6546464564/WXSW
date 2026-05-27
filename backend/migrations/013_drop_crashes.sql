-- 013_drop_crashes.sql
-- 移除 App 崩溃上报功能后，删除历史 crashes 表.

DROP TABLE IF EXISTS crashes;
