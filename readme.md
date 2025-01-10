wget https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.0.zip
  101  unzip v0.8.0.zip

 wget https://github.com/pgbouncer/pgbouncer/archive/refs/tags/pgbouncer_1_23_1-fixed.zip
  241  unzip pgbouncer_1_23_1-fixed.zip

207  docker build --build-arg PG_MAJOR=16 -t sjc.vultrcr.com/imagehub/pgvector:16.0.8.0-singlebuild .
  208  docker ps -a
  209  docker images
  210  ls
  211  docker push sjc.vultrcr.com/imagehub/pgvector:16.0.8.0-singlebuild

