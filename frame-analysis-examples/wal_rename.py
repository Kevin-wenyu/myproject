import struct
import os
import argparse

"""

使用示例：
python3 wal_rename.py /home/kingbase/kevin/ --segment-size 16777216 --dry-run

WAL文件重命名工具 - 适用于KingbaseES/PostgreSQL

功能说明：
1. 解析WAL文件头中的LSN(Log Sequence Number)
2. 根据LSN计算原始文件名
3. 批量修复错误命名的WAL文件

作者：Kevin
版本：v1.0
最后更新：2025-04-17
"""

# WAL文件段大小，默认为16MB
XLOG_SEG_SIZE = 16 * 1024 * 1024  # 16MB

def parse_wal_file(file_path):
    try:
        with open(file_path, 'rb') as f:
            # 读取前24字节的头部信息
            header = f.read(24)
            if len(header) < 24:
                return None  # 文件头不完整
            
            # 解析时间线ID (4字节, 偏移4-8)
            xlp_tli = struct.unpack("<I", header[4:8])[0]
            
            # 解析xlp_pageaddr (8字节, 偏移8-16)
            xlp_pageaddr = struct.unpack("<Q", header[8:16])[0]
            
            # 计算逻辑段号
            logSegNo = xlp_pageaddr // XLOG_SEG_SIZE
            
            # 分解为逻辑日志ID和段ID
            log_id = logSegNo // 256      # 每个日志文件包含256个段
            seg_id = logSegNo % 256      # 段ID在日志文件中的索引

            # debug 信息
            #print(f"Debug信息: {file_path}")
            #print(f"xlp_tli={xlp_tli}, xlp_pageaddr={xlp_pageaddr}")
            #print(f"logSegNo={xlp_pageaddr}//{XLOG_SEG_SIZE}={logSegNo}")
            #print(f"log_id={logSegNo}//256={log_id}, seg_id={logSegNo}%256={seg_id}")

            
            # 生成标准WAL文件名
            new_name = f"{xlp_tli:08X}{log_id:08X}{seg_id:08X}"
            return new_name
    except Exception as e:
        print(f"解析文件 {file_path} 时出错: {e}")
        return None

def main():
    # 在函数开头声明全局变量
    global XLOG_SEG_SIZE

    parser = argparse.ArgumentParser(description='WAL文件重命名工具')
    parser.add_argument('wal_dir', help='WAL文件目录路径')
    parser.add_argument('--segment-size', type=int, default=XLOG_SEG_SIZE,
                        help='指定WAL段大小（字节），默认16MB')
    parser.add_argument('--dry-run', action='store_true', help='试运行模式')
    args = parser.parse_args()

    # 更新全局变量值
    XLOG_SEG_SIZE = args.segment_size

    # 处理文件
    #processed = 0
    for filename in os.listdir(args.wal_dir):
        file_path = os.path.join(args.wal_dir, filename)
        
        # 跳过子目录和非文件项
        if not os.path.isfile(file_path):
            continue
        
        # 解析WAL文件获取新文件名
        new_name = parse_wal_file(file_path)
        if not new_name:
            continue  # 跳过解析失败的文件
        
        # 如果文件名已正确则跳过
        if filename == new_name:
            print(f"[跳过] {filename} 已为正确名称")
            continue
        
        # 构造新路径并处理文件冲突
        new_path = os.path.join(args.wal_dir, new_name)
        if os.path.exists(new_path):
            print(f"[冲突] 目标文件 {new_name} 已存在，跳过 {filename}")
            continue
        
        # 执行重命名操作
        if args.dry_run:
            print(f"[预览] 将重命名 {filename} => {new_name}")
        else:
            try:
                os.rename(file_path, new_path)
                print(f"[成功] 已重命名 {filename} => {new_name}")
                #processed += 1
            except Exception as e:
                print(f"[错误] 重命名 {filename} 失败: {str(e)}")
        # 输出统计信息
        #print(f"\n[操作完成] 共处理 {processed} 个文件")
        #if args.dry_run:
        #    print("提示：使用前请通过--dry-run参数验证结果")

if __name__ == "__main__":
    main()
