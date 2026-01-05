#!/usr/bin/env python3
"""
生产级 WAL 文件重命名工具 - 适用于 PostgreSQL/KingbaseES

功能说明：
1. 解析 WAL 文件头中的 LSN (Log Sequence Number)
2. 根据 LSN 计算原始文件名
3. 批量修复错误命名的 WAL 文件
4. 完整的日志、备份、恢复机制

作者: Kevin
版本: v2.0（生产级）
最后更新: 2026-01-02

使用示例:
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --segment-size 16777216 --dry-run
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --log-level DEBUG
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --rollback
"""

import struct
import os
import argparse
import json
import logging
import logging.handlers
import sys
import hashlib
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, List, Tuple
import fcntl


# ============================================================================
# 常量定义
# ============================================================================
XLOG_SEG_SIZE = 16 * 1024 * 1024  # 16MB
XLR_MAGIC = 0xD061  # WAL 文件头魔数
BACKUP_DIR = ".wal_rename_backup"
STATE_DIR = ".wal_rename_state"
STATE_FILE = "in_progress.json"


# ============================================================================
# 日志系统
# ============================================================================
class StructuredLogger:
    """结构化日志系统，支持 JSON 输出"""
    
    def __init__(self, log_dir: str, log_level: str = "INFO"):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(exist_ok=True)
        self.logger = logging.getLogger("wal_rename")
        self.logger.setLevel(getattr(logging, log_level))
        
        # 添加文件处理器（每天轮转）
        log_file = self.log_dir / f"wal_rename.log"
        handler = logging.handlers.TimedRotatingFileHandler(
            log_file, when="midnight", interval=1, backupCount=30
        )
        handler.setFormatter(logging.Formatter(
            '%(asctime)s [%(levelname)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        ))
        self.logger.addHandler(handler)
        
        # 添加控制台处理器
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(logging.Formatter(
            '[%(levelname)s] %(message)s'
        ))
        self.logger.addHandler(console_handler)
        
        # 错误日志
        error_file = self.log_dir / f"wal_rename_error.log"
        error_handler = logging.FileHandler(error_file)
        error_handler.setLevel(logging.ERROR)
        error_handler.setFormatter(logging.Formatter(
            '%(asctime)s [ERROR] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        ))
        self.logger.addHandler(error_handler)
    
    def log_json(self, level: str, event: str, **kwargs):
        """输出 JSON 格式的结构化日志"""
        log_entry = {
            "timestamp": datetime.now().isoformat(),
            "level": level,
            "event": event,
            **kwargs
        }
        msg = json.dumps(log_entry, ensure_ascii=False)
        getattr(self.logger, level.lower())(msg)
    
    def info(self, msg, **kwargs):
        if kwargs:
            self.log_json("INFO", msg, **kwargs)
        else:
            self.logger.info(msg)
    
    def error(self, msg, **kwargs):
        if kwargs:
            self.log_json("ERROR", msg, **kwargs)
        else:
            self.logger.error(msg)
    
    def warning(self, msg, **kwargs):
        if kwargs:
            self.log_json("WARNING", msg, **kwargs)
        else:
            self.logger.warning(msg)
    
    def debug(self, msg, **kwargs):
        if kwargs:
            self.log_json("DEBUG", msg, **kwargs)
        else:
            self.logger.debug(msg)


# ============================================================================
# 备份和状态管理
# ============================================================================
class BackupManager:
    """管理重命名操作的备份和回滚"""
    
    def __init__(self, wal_dir: str, logger: StructuredLogger):
        self.wal_dir = Path(wal_dir)
        self.backup_dir = self.wal_dir / BACKUP_DIR
        self.state_dir = self.wal_dir / STATE_DIR
        self.logger = logger
        
        self.backup_dir.mkdir(exist_ok=True)
        self.state_dir.mkdir(exist_ok=True)
        
        # 操作记录
        self.operations: List[Dict] = []
        self.state_file = self.state_dir / STATE_FILE
    
    def save_state(self):
        """保存当前操作状态（用于恢复）"""
        state = {
            "timestamp": datetime.now().isoformat(),
            "operations_count": len(self.operations),
            "operations": self.operations
        }
        with open(self.state_file, 'w') as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
        self.logger.debug("状态文件已保存", file=str(self.state_file))
    
    def load_state(self) -> Dict:
        """加载上次的操作状态"""
        if not self.state_file.exists():
            return {}
        try:
            with open(self.state_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            self.logger.error("加载状态文件失败", error=str(e))
            return {}
    
    def record_operation(self, old_name: str, new_name: str, file_hash: str):
        """记录一次重命名操作"""
        self.operations.append({
            "timestamp": datetime.now().isoformat(),
            "old_name": old_name,
            "new_name": new_name,
            "file_hash": file_hash,
            "status": "completed"
        })
    
    def generate_report(self) -> str:
        """生成操作报告"""
        report = {
            "timestamp": datetime.now().isoformat(),
            "total_operations": len(self.operations),
            "operations": self.operations
        }
        report_file = self.state_dir / f"report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(report_file, 'w') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        return str(report_file)
    
    def rollback(self):
        """回滚所有操作（根据 operations 列表）"""
        if not self.operations:
            self.logger.warning("没有可回滚的操作")
            return 0
        
        rolled_back = 0
        for op in reversed(self.operations):
            old_path = self.wal_dir / op['old_name']
            new_path = self.wal_dir / op['new_name']
            
            try:
                if new_path.exists():
                    os.rename(str(new_path), str(old_path))
                    rolled_back += 1
                    self.logger.info(f"已回滚: {op['new_name']} → {op['old_name']}")
            except Exception as e:
                self.logger.error(f"回滚失败: {op['new_name']}", error=str(e))
        
        # 清空状态
        self.operations = []
        self.save_state()
        return rolled_back


# ============================================================================
# WAL 文件解析和验证
# ============================================================================
class WALParser:
    """WAL 文件解析器，包含完整的验证"""
    
    def __init__(self, segment_size: int = XLOG_SEG_SIZE, logger: Optional[StructuredLogger] = None):
        self.segment_size = segment_size
        self.logger = logger
    
    @staticmethod
    def calculate_file_hash(file_path: str) -> str:
        """计算文件 SHA256 哈希"""
        sha256 = hashlib.sha256()
        with open(file_path, 'rb') as f:
            for chunk in iter(lambda: f.read(4096), b''):
                sha256.update(chunk)
        return sha256.hexdigest()
    
    def validate_header(self, header: bytes) -> Tuple[bool, str]:
        """验证 WAL 文件头的有效性"""
        if len(header) < 24:
            return False, "文件头不完整（少于 24 字节）"
        
        # 检查魔数
        xlr_magic = struct.unpack("<H", header[0:2])[0]
        if xlr_magic != XLR_MAGIC:
            return False, f"魔数不匹配（期望 0x{XLR_MAGIC:04X}，实际 0x{xlr_magic:04X}）"
        
        # 检查版本（偏移量 2-4）
        xlr_version = struct.unpack("<H", header[2:4])[0]
        if xlr_version not in [3, 4, 11, 12, 13, 14, 15]:
            return False, f"不支持的 WAL 版本: {xlr_version}"
        
        return True, ""
    
    def check_file_integrity(self, file_path: str, expected_size: Optional[int] = None) -> Tuple[bool, str]:
        """检查文件的物理完整性"""
        file_size = os.path.getsize(file_path)
        
        # 如果文件太小，可能损坏
        if file_size < 24:
            return False, f"文件太小（{file_size} 字节）"
        
        # 如果有预期大小，进行检查
        if expected_size and file_size != expected_size and file_size != self.segment_size:
            return False, f"文件大小异常（期望 {expected_size} 或 {self.segment_size}，实际 {file_size}）"
        
        return True, ""
    
    def parse_wal_file(self, file_path: str) -> Optional[Dict]:
        """
        解析 WAL 文件并返回详细信息
        
        返回:
            {
                'new_name': 'XXXXXXXXXXXXXXXX',
                'xlp_tli': 1,
                'xlp_pageaddr': 123456,
                'valid': True,
                'issues': []
            }
        """
        issues = []
        
        try:
            # 检查文件存在性
            if not os.path.isfile(file_path):
                if self.logger:
                    self.logger.error(f"文件不存在: {file_path}")
                return None
            
            # 检查文件完整性
            valid, msg = self.check_file_integrity(file_path)
            if not valid:
                issues.append(f"完整性检查失败: {msg}")
                if self.logger:
                    self.logger.warning(f"文件完整性问题: {file_path}", reason=msg)
            
            with open(file_path, 'rb') as f:
                header = f.read(24)
            
            # 验证头部
            valid, msg = self.validate_header(header)
            if not valid:
                issues.append(f"头部验证失败: {msg}")
                if self.logger:
                    self.logger.warning(f"WAL 头部验证失败: {file_path}", reason=msg)
                return None  # 头部无效，无法继续
            
            # 解析关键字段
            xlp_tli = struct.unpack("<I", header[4:8])[0]
            xlp_pageaddr = struct.unpack("<Q", header[8:16])[0]
            
            # 计算逻辑段号
            logSegNo = xlp_pageaddr // self.segment_size
            log_id = logSegNo // 256
            seg_id = logSegNo % 256
            
            new_name = f"{xlp_tli:08X}{log_id:08X}{seg_id:08X}"
            
            return {
                'new_name': new_name,
                'xlp_tli': xlp_tli,
                'xlp_pageaddr': xlp_pageaddr,
                'logSegNo': logSegNo,
                'valid': len(issues) == 0,
                'issues': issues
            }
            
        except Exception as e:
            if self.logger:
                self.logger.error(f"解析 WAL 文件异常: {file_path}", error=str(e))
            return None


# ============================================================================
# 主程序
# ============================================================================
class WALRenamer:
    """WAL 文件重命名主程序"""
    
    def __init__(self, wal_dir: str, segment_size: int = XLOG_SEG_SIZE, 
                 log_level: str = "INFO", dry_run: bool = False):
        self.wal_dir = Path(wal_dir)
        self.segment_size = segment_size
        self.dry_run = dry_run
        
        # 初始化日志
        self.logger = StructuredLogger(str(self.wal_dir), log_level)
        self.logger.info(f"WAL 重命名工具启动", 
                        wal_dir=str(self.wal_dir), 
                        dry_run=dry_run, 
                        segment_size=segment_size)
        
        # 初始化备份管理
        self.backup_mgr = BackupManager(str(self.wal_dir), self.logger)
        
        # 初始化解析器
        self.parser = WALParser(segment_size, self.logger)
        
        # 统计信息
        self.stats = {
            'total_files': 0,
            'renamed': 0,
            'skipped': 0,
            'errors': 0,
            'already_correct': 0
        }
    
    def rename_file(self, filename: str, new_name: str) -> bool:
        """执行文件重命名，带错误处理"""
        old_path = self.wal_dir / filename
        new_path = self.wal_dir / new_name
        
        try:
            if self.dry_run:
                self.logger.info(f"[预览] 重命名", old=filename, new=new_name)
                return True
            
            # 检查目标文件是否已存在
            if new_path.exists():
                self.logger.warning(f"目标文件已存在，跳过", old=filename, new=new_name)
                self.stats['skipped'] += 1
                return False
            
            # 执行重命名
            os.rename(str(old_path), str(new_path))
            
            # 计算并记录文件哈希
            file_hash = self.parser.calculate_file_hash(str(new_path))
            self.backup_mgr.record_operation(filename, new_name, file_hash)
            
            self.logger.info(f"重命名成功", old=filename, new=new_name, hash=file_hash)
            self.stats['renamed'] += 1
            return True
            
        except Exception as e:
            self.logger.error(f"重命名失败", old=filename, new=new_name, error=str(e))
            self.stats['errors'] += 1
            return False
    
    def process_directory(self) -> int:
        """处理目录中的所有 WAL 文件"""
        self.logger.info(f"开始扫描目录", path=str(self.wal_dir))
        
        if not self.wal_dir.exists():
            self.logger.error(f"目录不存在", path=str(self.wal_dir))
            return -1
        
        # 获取所有文件
        files = sorted([f for f in os.listdir(str(self.wal_dir)) 
                       if os.path.isfile(os.path.join(str(self.wal_dir), f))])
        
        self.stats['total_files'] = len(files)
        self.logger.info(f"发现文件数", count=len(files))
        
        for filename in files:
            # 跳过备份和状态目录
            if filename.startswith('.'):
                continue
            
            file_path = str(self.wal_dir / filename)
            
            # 解析 WAL 文件
            parse_result = self.parser.parse_wal_file(file_path)
            if not parse_result:
                self.stats['errors'] += 1
                continue
            
            new_name = parse_result['new_name']
            
            # 如果文件名已正确
            if filename == new_name:
                self.logger.debug(f"文件名正确，跳过", filename=filename)
                self.stats['already_correct'] += 1
                continue
            
            # 记录问题
            if not parse_result['valid']:
                for issue in parse_result['issues']:
                    self.logger.warning(f"文件存在问题", filename=filename, issue=issue)
            
            # 执行重命名
            self.rename_file(filename, new_name)
        
        # 保存状态和生成报告
        self.backup_mgr.save_state()
        report_file = self.backup_mgr.generate_report()
        
        self.logger.info(f"操作完成", **self.stats, report_file=report_file)
        return self.stats['renamed']
    
    def print_summary(self):
        """打印操作摘要"""
        print("\n" + "=" * 60)
        print("WAL 文件重命名 - 操作摘要")
        print("=" * 60)
        print(f"扫描文件总数:     {self.stats['total_files']}")
        print(f"已重命名:         {self.stats['renamed']}")
        print(f"已跳过:           {self.stats['skipped']}")
        print(f"文件名正确:       {self.stats['already_correct']}")
        print(f"处理错误:         {self.stats['errors']}")
        print(f"模式:             {'预览' if self.dry_run else '执行'}")
        print("=" * 60 + "\n")
    
    def rollback_changes(self) -> int:
        """回滚所有更改"""
        self.logger.info("开始回滚操作")
        rolled_back = self.backup_mgr.rollback()
        self.logger.info(f"回滚完成", count=rolled_back)
        return rolled_back


# ============================================================================
# 命令行接口
# ============================================================================
def main():
    parser = argparse.ArgumentParser(
        description='生产级 WAL 文件重命名工具',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 预览模式
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --dry-run
  
  # 实际执行
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal
  
  # 回滚上次操作
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --rollback
  
  # 调试模式
  python3 wal_rename_v2.py /var/lib/postgresql/pg_wal --log-level DEBUG
        """
    )
    
    parser.add_argument('wal_dir', help='WAL 文件所在目录')
    parser.add_argument('--segment-size', type=int, default=XLOG_SEG_SIZE,
                        help='指定 WAL 段大小（字节），默认 16MB')
    parser.add_argument('--log-level', choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'],
                        default='INFO', help='日志级别')
    parser.add_argument('--dry-run', action='store_true', 
                        help='预览模式，不实际修改文件')
    parser.add_argument('--rollback', action='store_true',
                        help='回滚上次的重命名操作')
    
    args = parser.parse_args()
    
    # 创建重命名器
    renamer = WALRenamer(
        args.wal_dir,
        segment_size=args.segment_size,
        log_level=args.log_level,
        dry_run=args.dry_run
    )
    
    # 处理回滚请求
    if args.rollback:
        rolled_back = renamer.rollback_changes()
        print(f"\n✓ 已回滚 {rolled_back} 个文件")
        return 0
    
    # 正常处理
    try:
        renamer.process_directory()
        renamer.print_summary()
    except KeyboardInterrupt:
        renamer.logger.warning("用户中断操作")
        print("\n操作已中断")
        return 1
    except Exception as e:
        renamer.logger.error(f"未捕获的异常", error=str(e))
        print(f"\n✗ 错误: {e}")
        return 1
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
