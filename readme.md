wget https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.0.zip
  101  unzip v0.8.0.zip

 wget https://github.com/pgbouncer/pgbouncer/archive/refs/tags/pgbouncer_1_23_1-fixed.zip
  241  unzip pgbouncer_1_23_1-fixed.zip

207  docker build --build-arg PG_MAJOR=16 -t sjc.vultrcr.com/imagehub/pgvector:16.0.8.0-singlebuild .
  208  docker ps -a
  209  docker images
  210  ls
  211  docker push sjc.vultrcr.com/imagehub/pgvector:16.0.8.0-singlebuild



下面给你一套在 Docker Compose 下运行、且持续写入的 PostgreSQL 17（pgvector 镜像）企业级备份与还原方案。
特点：不停机热备（pg_basebackup + WAL 归档）＋ 时间点恢复（PITR）＋ 可自动化清理与演练。

1) 调整 Compose：挂载备份与日志目录

在你现有的 docker-compose.yml 基础上做三点改动：

明确 PGDATA 到你实际的数据目录（你映射成了 /var/postgresql/pgdata，要告知 PostgreSQL）

增加一个备份挂载点（例如 /backups）

日志目录如果要持久化，也挂出来（你在 conf 里设了 /var/log/postgresql）

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
      PGDATA: /var/postgresql/pgdata                  # ★ 告诉 PG 实际数据目录
    ports:
      - "5432:5432"
    volumes:
      - ./postgres_data:/var/postgresql/pgdata       # ★ 数据持久化
      - ./pgbackups:/backups                         # ★ 备份与 WAL 归档
      - ./postgresql.conf:/etc/postgresql/postgresql.conf
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
      - ./pglogs:/var/log/postgresql                 # 可选：持久化日志
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          memory: 3G
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s


目录权限：宿主机上的 ./postgres_data、./pgbackups、./pglogs 建议 chmod 700 并由容器内的 postgres 用户可写（通常 Docker 会映射为 root:root，但容器里进程以 postgres 运行；不用手动 chown，挂载目录即可，若遇权限报错再调整）。

2) 调整 postgresql.conf：开启 WAL 归档

你已有：

wal_level = replica
...
log_directory = '/var/log/postgresql'


补充两行，把 WAL 归档到你挂载的 /backups 下：

archive_mode = on
archive_command = 'test ! -f /backups/wal/%f && cp %p /backups/wal/%f'


说明：

archive_mode=on：启用 WAL 归档

archive_command：把已完成的 WAL 段复制到 /backups/wal/。test ! -f 用于幂等防覆盖。

请确保目录存在：mkdir -p ./pgbackups/wal

改完后 docker compose up -d（或 docker restart pgvector）让配置生效。

3)（一次性）创建复制/备份专用用户（可选但推荐）

如果你只在容器内用 docker exec 执行 pg_basebackup，直接用 postgres 用户即可。
若你想从容器外或其他机器跑备份，建议建 replicator：

-- 放到 init.sql（新库会自动执行），或手工连上执行
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'StrongPass!';

-- 若需要远程跑备份，还要在 pg_hba.conf 里加一条（仅示例，请按网段收紧）
-- host replication replicator 192.168.0.0/16 md5

4) 在线热备：pg_basebackup（不会中断写入）

定时备份命令（宿主机执行）：

docker exec -t pgvector \
  pg_basebackup -U postgres \
  -D /backups/base_$(date +%F_%H%M) \
  -Ft -z -X stream -P


会生成：

./pgbackups/base_2025-11-03_0930/base.tar.gz
./pgbackups/base_2025-11-03_0930/pg_wal.tar.gz


含义：

-Ft -z：tar.gz 压缩

-X stream：流式带上当前 WAL，保证一致性

-P：显示进度

你也可以用 -R 让它生成 standby.signal/postgresql.auto.conf 以便快速搭只读从库；此处做备份不需要。

5) 自动化：Cron & 保留策略

宿主机 crontab（示例：每天 03:00 备份，保留 7 天）

0 3 * * * docker exec pgvector pg_basebackup -U postgres \
    -D /backups/base_$(date +\%F_%H%M) -Ft -z -X stream -P \
 && find /your/compose/path/pgbackups -maxdepth 1 -type d -name 'base_*' -mtime +7 -exec rm -rf {} \;


建议把 ./pgbackups 做二次备份到对象存储（S3、B2）或异地主机：

rclone copy ./pgbackups remote:s3-bucket/pgbackups --transfers=4 --checkers=8

或者用 restic/velero 等专业工具。

6) 时间点恢复（PITR） Runbook

场景：主库损坏/误删数据，希望恢复到 2025-11-03 09:59:00 AEDT

步骤 1）停库

docker compose stop postgres


步骤 2）清空数据目录

⚠️ 这会覆盖当前数据，请先快照/备份 ./postgres_data（哪怕坏的也留一份）

rm -rf ./postgres_data/*


步骤 3）解包最新一次基础备份

LATEST=./pgbackups/base_2025-11-03_0930
tar -xzf "$LATEST/base.tar.gz" -C ./postgres_data
# 可选：有 pg_wal.tar.gz 的也解开（一般恢复时不必手动解）
# tar -xzf "$LATEST/pg_wal.tar.gz" -C ./postgres_data


步骤 4）配置恢复
把如下两行追加到容器内将要使用的配置文件（你用的是挂载的 /etc/postgresql/postgresql.conf；也可以改 ./postgres_data/postgresql.conf，两者任选其一保持一致）：

restore_command = 'cp /backups/wal/%f %p'
recovery_target_time = '2025-11-03 09:59:00+11'   # Melbourne 时区 +11


创建恢复信号文件（PostgreSQL 12+ 用 recovery.signal 控制恢复流程）：

touch ./postgres_data/recovery.signal


步骤 5）启动容器

docker compose up -d postgres


PostgreSQL 会自动按 restore_command 从 /backups/wal 回放 WAL，回放至 recovery_target_time 停止，随后自动清除 recovery.signal 并转为可写运行。

验证：

docker exec -it pgvector psql -U postgres -c "select now(), pg_is_in_recovery();"
-- 应显示 pg_is_in_recovery = f（false）


可选：恢复到“最近一致点”而不是具体时间
把 recovery_target_time 注释掉，或用：

recovery_target = 'immediate'

7) 逻辑备份（单库/单表迁移补充）

不满足 PITR，但用于结构迁移非常方便

# 导出（自定义格式）
docker exec pgvector pg_dump -U postgres -Fc yourdb > ./pgbackups/yourdb_$(date +%F).dump

# 还原到新库
docker exec -i pgvector createdb -U postgres newdb
docker exec -i pgvector pg_restore -U postgres -d newdb < ./pgbackups/yourdb_2025-11-03.dump

8) 灾备演练（在线验证备份可用，零打扰生产）

用临时容器在隔离目录验证一次恢复流程：

# 准备一个临时还原目录
mkdir -p ./restore_sandbox && rm -rf ./restore_sandbox/*

# 解包最新备份
tar -xzf ./pgbackups/base_2025-11-03_0930/base.tar.gz -C ./restore_sandbox

# 追加恢复配置（指向同一 WAL 归档）
echo "restore_command = 'cp /backups/wal/%f %p'" >> ./restore_sandbox/postgresql.conf
echo "recovery_target = 'immediate'" >> ./restore_sandbox/postgresql.conf
touch ./restore_sandbox/recovery.signal

# 起一个一次性容器做恢复验证（映射同一 ./pgbackups 以访问 WAL）
docker run --rm \
  -v "$(pwd)/restore_sandbox":/var/postgresql/pgdata \
  -v "$(pwd)/pgbackups":/backups \
  -e PGDATA=/var/postgresql/pgdata \
  pgvector/pgvector:pg17 \
  postgres -D /var/postgresql/pgdata


若能成功启动、且 pg_is_in_recovery() 返回 f，说明备份可用。

9) 常见坑与建议

一定要有 archive_mode=on + 正确的 archive_command，否则即使有 basebackup 也无法做 PITR。

WAL 归档目录不能爆满：结合对象存储或异地服务器做二次备份与生命周期管理。

监控归档失败：查看日志 ./pglogs/；归档失败会阻塞 WAL 回收、导致磁盘被吃满。

权限问题：/backups/wal 必须容器内可写；首次 mkdir -p ./pgbackups/wal。

时区：你用的是 Australia/Melbourne（夏令时 +11），PITR 时间点请用绝对时间并写明时区。

pgvector：与备份流程无冲突，属于普通扩展；但如果用到外部向量文件/模型，记得一并备份。

测试恢复：把演练脚本纳入例行作业（至少每月一次），确保真正可恢复。

如果你愿意，我可以把上面命令打包成：

backup.sh（执行与清理）

pitr-restore.sh（传入目标时间自动恢复）

一份 crontab 模板

直接放进你的 repo 即可用。需要的话我就按你当前目录结构生成。


你想把这条命令（容器内执行 pg_basebackup）改成通过 docker compose 来运行，
下面是等价的写法与几种实用方式。

✅ 方式 1：一次性执行（推荐）

直接使用 docker compose exec：

docker compose exec -T postgres \
  pg_basebackup -U postgres \
  -D /backups/base_$(date +%F_%H%M) \
  -Ft -z -X stream -P


说明：

-T 关闭伪终端（cron 下更稳）；

postgres 是服务名（你的 compose 文件里是 postgres:）；

其余参数与原命令完全一致；

备份会写到挂载的 ./pgbackups/ 目录下（宿主机能直接看到）。

🕒 方式 2：配合 cron 自动备份

假设 docker-compose.yml 与 pgbackups/ 同目录。
编辑宿主机的 crontab：

0 3 * * * cd /path/to/compose && \
  docker compose exec -T postgres \
    pg_basebackup -U postgres \
    -D /backups/base_$(date +\%F_%H%M) \
    -Ft -z -X stream -P && \
  find ./pgbackups -maxdepth 1 -type d -name 'base_*' -mtime +7 -exec rm -rf {} \;


这条任务每天凌晨 3 点执行热备，保留 7 天。

🧰 方式 3：定义成 compose 命令（方便一键运行）

你也可以在 docker-compose.yml 里加一个辅助服务（或命令别名）：

services:
  postgres:
    image: pgvector/pgvector:pg17
    ...
  backup:
    image: pgvector/pgvector:pg17
    depends_on:
      - postgres
    entrypoint: >
      bash -c "pg_basebackup -h postgres -U postgres
               -D /backups/base_$(date +%F_%H%M)
               -Ft -z -X stream -P"
    volumes:
      - ./pgbackups:/backups


然后运行：

docker compose run --rm backup


它会启动一个临时容器，通过网络连接到主库服务 postgres 并执行热备，
备份文件同样输出到宿主机的 ./pgbackups。

✅ 建议用法总结
需求	推荐命令
临时手动备份	docker compose exec -T postgres pg_basebackup ...
定时自动化	在 cron 里执行上面命令
CI/CD / 一键任务	docker compose run --rm backup 临时容器

如果你希望我帮你生成一个可以直接放进项目根目录的脚本（例如 backup.sh），
支持自动创建目录、压缩、清理旧备份、日志记录，我可以直接写一份。是否要我帮你生成？


这是日志目录权限问题：你把 log_directory = '/var/log/postgresql' 挂到宿主机 (./pglogs:/var/log/postgresql)，但容器内的 postgres 用户对该目录无写权限，所以启动时报：

FATAL:  could not open log file "/var/log/postgresql/postgresql-....log": Permission denied


给你三种可靠修法，任选其一（按容器最佳实践由上到下推荐）：

方案 A（容器推荐）：把日志打到 stderr，用 docker compose logs

把 postgresql.conf 改为：

log_destination = 'stderr'
logging_collector = off
# 注：去掉/忽略 log_directory 设置


然后重载：

docker compose restart postgres


之后用：

docker compose logs -f postgres


即可查看日志。这是容器里最常用的做法。

方案 B：仍用文件日志，但写到 PGDATA 相对目录

让日志写在 PGDATA 下（容器内肯定可写）：

修改 postgresql.conf：

logging_collector = on
log_directory = 'log'   # 相对目录，位于 PGDATA 内
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'


创建目录并确保权限（任选其一执行）：

在宿主机（你的 PGDATA 映射是 ./postgres_data）：

mkdir -p ./postgres_data/log
# 获取容器内 postgres 用户的 uid/gid
uid=$(docker compose exec -T postgres id -u postgres)
gid=$(docker compose exec -T postgres id -g postgres)
sudo chown -R $uid:$gid ./postgres_data/log
sudo chmod 700 ./postgres_data/log


或在容器内：

docker compose exec -u root postgres sh -c \
  "mkdir -p /var/postgresql/pgdata/log && chown -R postgres:postgres /var/postgresql/pgdata/log && chmod 700 /var/postgresql/pgdata/log"


重启：

docker compose restart postgres

方案 C：继续使用你挂载的 /var/log/postgresql，修正宿主机目录权限

如果你一定要把日志放 /var/log/postgresql：

在宿主机修正 ./pglogs 目录归属为容器内的 postgres：

uid=$(docker compose exec -T postgres id -u postgres)
gid=$(docker compose exec -T postgres id -g postgres)
sudo chown -R $uid:$gid ./pglogs
sudo chmod 700 ./pglogs


若你的宿主机启用了 SELinux（常见于 RHEL/CentOS/Fedora），需要在卷挂载后面加 :z 或 :Z：

- ./pglogs:/var/log/postgresql:z


然后 docker compose up -d 让标签生效。

保留你原来的 logging_collector = on 与 log_directory = '/var/log/postgresql'，重启：

docker compose restart postgres

附：启动时出现
PostgreSQL Database directory appears to contain a database; Skipping initialization


这是正常提示：PGDATA 里已有数据，因此跳过初始化。

建议：在容器环境里，最省心的是方案 A（stderr + docker compose logs）。
如果你更想保留文件归档，选方案 B（写到 PGDATA 相对目录），权限最少、最稳定。


现象说明你只得到了一个空目录，而没有期望的 base.tar.gz / pg_wal.tar.gz 文件。
用 -Ft -z 时，pg_basebackup 应该在你指定的目录里生成这两个压缩包（至少会有 base.tar.gz）。

最常见原因与排查步骤如下（按优先级）：

1) 先看返回码与实际输出
# 重新跑一遍，并打开详细日志
docker compose exec -T postgres \
  sh -lc 'pg_basebackup -U postgres -D /backups/base_$(date +%F_%H%M) -Ft -z -X stream -v -P'; echo "exit code: $?"


观察是否有诸如 “permission denied / could not create file / not enough free space / connection error”的报错。

exit code: 0 才算成功。

2) 确认目录与文件是否真的为空（容器内 & 宿主机各看一次）
# 容器内看
docker compose exec -T postgres sh -lc 'ls -lah /backups; ls -lah /backups/base_*'

# 宿主机看（compose 文件所在目录）
ls -lah ./pgbackups
ls -lah ./pgbackups/base_2025-11-03_2140


期望能看到：base.tar.gz（必有）以及 pg_wal.tar.gz（因为你用了 -X stream）。

3) 校验权限（/backups 卷是否可写）

很多时候能创建目录但写文件失败是宿主机权限/SELinux 导致的。

# 看容器内 /backups 目录权限与当前用户
docker compose exec -T postgres sh -lc 'id; ls -ld /backups; ls -ld /backups/base_*'

# 如需修复宿主机目录属主（将其改为容器内 postgres 的 uid/gid）
uid=$(docker compose exec -T postgres id -u postgres | tr -d '\r')
gid=$(docker compose exec -T postgres id -g postgres | tr -d '\r')
sudo chown -R $uid:$gid ./pgbackups
sudo chmod 700 ./pgbackups


如果你的宿主机是 RHEL/CentOS/Fedora，SELinux 可能拦截写入。把卷挂载加上 :z：

- ./pgbackups:/backups:z


然后 docker compose up -d 再试。

4) 磁盘空间是否足够
# 宿主机
df -h ./pgbackups
# 容器内（看 overlay 的可用空间）
docker compose exec -T postgres sh -lc 'df -h /backups'

5) 服务器端是否允许备份/复制

你用的是 postgres 超级用户，按理有权限。但如果 pg_hba.conf 有限制（尤其是你改过），或库没跑起来，也会失败。可先测连通：

docker compose exec -T postgres psql -U postgres -c "select version();"

6) 快速验证用“目录格式”（排除 tar 压缩因素）

先用plain 目录格式试一次（成功后再换回 tar.gz）：

docker compose exec -T postgres \
  sh -lc 'pg_basebackup -U postgres -D /backups/base_plain_$(date +%F_%H%M) -Fp -X stream -v -P && ls -lah /backups/base_plain_* | head -n 50'


目录格式会直接生成一堆文件夹（看起来更直观）。如果这能成功，说明问题多半在于 tar.gz 写入/权限。

7) 一条更健壮的命令（含预检查、确保目录存在）
docker compose exec -T postgres sh -lc '
set -e
TS=$(date +%F_%H%M)
OUT=/backups/base_${TS}
mkdir -p "$OUT"
[ -w /backups ] && echo "OK: /backups writable" || (echo "ERR: /backups not writable" >&2; exit 1)
pg_basebackup -U postgres -D "$OUT" -Ft -z -X stream -v -P
echo "Done. Files in $OUT:"
ls -lah "$OUT"
'

期望结果（tar 模式）

/backups/base_YYYY-MM-DD_HHMM/ 目录里至少应该有：

base.tar.gz（必有）

pg_wal.tar.gz（指定 -X stream 时应有）

如果按上面的排查仍只剩空目录，把第 1 步的完整输出贴出来，我可以根据错误信息定位是权限、SELinux、空间、还是连接/配置问题。