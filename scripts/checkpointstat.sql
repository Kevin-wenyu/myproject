\echo checkpoints_timed：计划检查点的发生次数，这种检查点是checkpoint_timeout参数规定的超时达到后系统启动的checkpoint；
\echo checkpoints_req：非计划检查点的次数。有些朋友把这个指标定义为手工检查点的次数，实际上这是不准确的。手工检查点是因为执行某些命令触发的检查点，这个指标包含这类检查点，除此之外，还有一类xlog checkpoint检查点也属于这类检查点。xlog ckpt是指当某些数据库预定的阈值达到时启动的检查点，比如WAL已经超出了max_wal_size或者checkpoint_segments，也会触发xlog ckpt；
\echo checkpoint_write_time：ckpt写入的总时长(ms)；
\echo checkpoint_sync_time：ckpt同步文件的总时长(ms)；
\echo buffers_checkpoint：由checkpointer清理的脏块；
\echo buffers_clean：由bgwriter清理的脏块数量；
\echo buffers_backend：由backend清理的脏块数量；
\echo maxwritten_clean：bgwriter清理脏块的时候达到bgwriter_lru_maxpages后终止写入批处理的次数，为了防止一次批量写入太大影响数据块IO性能，bgwriter每次都有写入的限制。不过这个参数的缺省值100太小，对于负载较高的数据库，需要加大；
\echo buffers_backend_fsync：backend被迫自己调用fsync来同步数据的计数，如果这个计数器不为零，说明当时的fsync队列已经满了，存储子系统肯定出现了性能问题；
\echo stats_reset：上一次RESET这些统计值的时间。
\echo
\x
select * from pg_stat_bgwriter;
