# PostgreSQL 17 (pgvector) Docker Compose 热备份与恢复指南

本文档描述了在 **Docker Compose** 下运行的 PostgreSQL 17 (pgvector) 实例中，如何实现在线热备份、时间点恢复 (PITR)以及日常日志和权限设置。

---

## 🗂 基础环境

**docker-compose.yml**

```yaml
version: '3.8'

services:
  postgres:
    image: pgvector/pgvector:pg17
    container_name: pgvector
    restart: always
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-your_secure_password}
      POSTGRES_INITDB_ARGS: --lc-numeric=en_US.UTF-8
      TZ: Australia/Melbourne
      PGDATA: /var/postgresql/pgdata
    ports:
      - "5432:5432"
    volumes:
      - ./postgres_data:/var/postgresql/pgdata       # 数据目录
      - ./pgbackups:/backups                         # 备份与 WAL 归档
      - ./postgresql.conf:/etc/postgresql/postgresql.conf
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
      - ./pglogs:/var/log/postgresql                 # 日志持久化
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

---

## ⚙️ PostgreSQL 配置

在 `postgresql.conf` 中添加 WAL 归档配置：

```conf
archive_mode = on
archive_command = 'test ! -f /backups/wal/%f && cp %p /backups/wal/%f'
```

创建 WAL 归档目录：

```bash
mkdir -p ./pgbackups/wal
chmod 700 ./pgbackups
```

重启容器使配置生效：

```bash
docker compose restart postgres
```

---

## 🔢 日志配置选项

### 方案 A (建议）：日志打到 stderr

```conf
log_destination = 'stderr'
logging_collector = off
```

使用 Docker 查看日志：

```bash
docker compose logs -f postgres
```

### 方案 B：日志写到 PGDATA

```conf
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
```

创建日志目录：

```bash
docker compose exec -u root postgres sh -c "mkdir -p /var/postgresql/pgdata/log && chown -R postgres:postgres /var/postgresql/pgdata/log && chmod 700 /var/postgresql/pgdata/log"
```

### 方案 C：日志持久化到挂载目录

确保目录可写或使用 SELinux 标签：

```bash
sudo chown -R 999:999 ./pglogs
sudo chmod 700 ./pglogs
```

或在 compose 中挂载时使用标签：

```yaml
- ./pglogs:/var/log/postgresql:z
```

---

## 🔢 在线热备份 (Base Backup)

PostgreSQL 通过 `pg_basebackup` 实现完整热备，无需停机或锁表。

```bash
docker compose exec -T postgres \
  pg_basebackup -U postgres \
  -D /backups/base_$(date +%F_%H%M) \
  -Ft -z -X stream -P
```

输出根目录示例：

```
/backups/base_2025-11-03_2140/
 ├─ base.tar.gz
 └─ pg_wal.tar.gz
```

| 参数          | 含义              |
| ----------- | --------------- |
| `-Ft -z`    | 以 tar.gz 压缩格式保存 |
| `-X stream` | 展开 WAL 日志，确保一致性 |
| `-P`        | 显示进度            |

---

## 🕗 定时自动备份 (Cron)

```bash
0 3 * * * cd /path/to/compose && \
  docker compose exec -T postgres \
    pg_basebackup -U postgres \
    -D /backups/base_$(date +\%F_%H%M) \
    -Ft -z -X stream -P && \
  find ./pgbackups -maxdepth 1 -type d -name 'base_*' -mtime +7 -exec rm -rf {} \;
```

---

## 🔑 权限配置

确保 `/backups` 容器内可写：

```bash
uid=$(docker compose exec -T postgres id -u postgres | tr -d '\r')
gid=$(docker compose exec -T postgres id -g postgres | tr -d '\r')
sudo chown -R $uid:$gid ./pgbackups
sudo chmod 700 ./pgbackups
```

SELinux 环境加 `:z` 标签：

```yaml
- ./pgbackups:/backups:z
```

---

## 🔄 热备份验证脚本

```bash
docker compose exec -T postgres sh -lc '
TS=$(date +%F_%H%M)
OUT=/backups/base_${TS}
mkdir -p "$OUT"
pg_basebackup -U postgres -D "$OUT" -Ft -z -X stream -v -P
echo "Done. Files in $OUT:"
ls -lah "$OUT"
'
```

---

## 🔄 时间点恢复 (PITR)

### 1. 停止 PostgreSQL

```bash
docker compose stop postgres
```

### 2. 清空数据目录并解压备份

```bash
rm -rf ./postgres_data/*
tar -xzf ./pgbackups/base_2025-11-03_2140/base.tar.gz -C ./postgres_data
```

### 3. 添加恢复配置

```conf
restore_command = 'cp /backups/wal/%f %p'
recovery_target_time = '2025-11-03 21:40:00+11'
```

然后创建恢复信号文件：

```bash
touch ./postgres_data/recovery.signal
```

### 4. 启动容器，回放 WAL

```bash
docker compose up -d postgres
```

确认恢复状态：

```bash
docker compose exec -T postgres \
  psql -U postgres -c "select now(), pg_is_in_recovery();"
```

`pg_is_in_recovery = f` 表示恢复完成。

---

## 🔄 灾备演练 (恢复测试)

```bash
mkdir -p ./restore_sandbox && rm -rf ./restore_sandbox/*

tar -xzf ./pgbackups/base_2025-11-03_2140/base.tar.gz -C ./restore_sandbox
echo "restore_command = 'cp /backups/wal/%f %p'" >> ./restore_sandbox/postgresql.conf
echo "recovery_target = 'immediate'" >> ./restore_sandbox/postgresql.conf
touch ./restore_sandbox/recovery.signal

docker run --rm \
  -v "$(pwd)/restore_sandbox":/var/postgresql/pgdata \
  -v "$(pwd)/pgbackups":/backups \
  -e PGDATA=/var/postgresql/pgdata \
  pgvector/pgvector:pg17 \
  postgres -D /var/postgresql/pgdata
```

---

## 🔢 逻辑备份和恢复

```bash
# 备份单库
 docker compose exec postgres pg_dump -U postgres -Fc mydb > ./pgbackups/mydb_$(date +%F).dump

# 恢复到新库
docker compose exec -T postgres createdb -U postgres newdb
docker compose exec -i postgres pg_restore -U postgres -d newdb < ./pgbackups/mydb_2025-11-03.dump
```

---

## 🔧 常见问题和注意事项

1. **确保 WAL 归档启用：** `archive_mode=on` + 正确的 `archive_command`
2. **盘空间：** 定期清理 `/backups/wal`，或使用 S3/rsync 存储库存档
3. **SELinux：** 如遇 `Permission denied`，加 `:z`标签或关闭 SELinux 限制
4. **恢复时间区：** 使用绝对时间（例如 +11 以区分处理处处处）
5. **演练备份：** 每月少做一次恢复验证。

---

本文档包含了所有实用命令，从配置、热备份、自动化到时间点恢复和日志处理，可直接用于生产环境。



```
wget https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.0.zip
  101  unzip v0.8.0.zip

 wget https://github.com/pgbouncer/pgbouncer/archive/refs/tags/pgbouncer_1_23_1-fixed.zip
  241  unzip pgbouncer_1_23_1-fixed.zip

207  docker build --build-arg PG_MAJOR=16 -t sjc.vultrcr.com/imagehub/pgvector:16.0.8.0-singlebuild .
  208  docker ps -a
  209  docker images
  210  ls
  211  docker push sjc.vultrcr.com/imagehub/pgvector:16.0.8.0-singlebuild
```