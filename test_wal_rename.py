#!/usr/bin/env python3
"""
WAL 文件重命名工具 - 单元测试

测试涵盖:
- 文件解析和验证
- 备份和恢复机制
- 日志系统
- 边界情况处理
"""

import unittest
import tempfile
import shutil
import struct
import json
import os
import sys
from pathlib import Path

# 导入被测试的模块
from wal_rename_v2 import (
    WALParser, BackupManager, StructuredLogger, 
    WALRenamer, XLOG_SEG_SIZE, XLR_MAGIC
)


# ============================================================================
# 测试工具函数
# ============================================================================
def create_test_wal_file(file_path: str, xlp_tli: int = 1, xlp_pageaddr: int = 0, 
                         add_garbage: bool = False):
    """创建测试用的 WAL 文件"""
    with open(file_path, 'wb') as f:
        # 构造 WAL 头部
        header = bytearray(24)
        
        # 魔数 (0-2)
        struct.pack_into("<H", header, 0, XLR_MAGIC)
        
        # 版本 (2-4)
        struct.pack_into("<H", header, 2, 15)
        
        # 时间线 ID (4-8)
        struct.pack_into("<I", header, 4, xlp_tli)
        
        # xlp_pageaddr (8-16)
        struct.pack_into("<Q", header, 8, xlp_pageaddr)
        
        # 其他字段 (16-24)
        struct.pack_into("<Q", header, 16, 0)
        
        f.write(bytes(header))
        
        # 填充到 16MB（如果需要）
        remaining = XLOG_SEG_SIZE - len(header)
        if add_garbage:
            f.write(b'\x00' * remaining)


# ============================================================================
# 测试用例
# ============================================================================
class TestWALParser(unittest.TestCase):
    """WAL 解析器测试"""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.parser = WALParser(XLOG_SEG_SIZE)
    
    def tearDown(self):
        shutil.rmtree(self.temp_dir)
    
    def test_parse_valid_wal_file(self):
        """测试解析有效的 WAL 文件"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        create_test_wal_file(test_file, xlp_tli=1, xlp_pageaddr=0)
        
        result = self.parser.parse_wal_file(test_file)
        
        self.assertIsNotNone(result)
        self.assertEqual(result['new_name'], '0000000100000000' + '00000000')
        self.assertEqual(result['xlp_tli'], 1)
        self.assertTrue(result['valid'])
    
    def test_parse_with_different_timeline(self):
        """测试不同时间线的 WAL 文件"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        create_test_wal_file(test_file, xlp_tli=5, xlp_pageaddr=0)
        
        result = self.parser.parse_wal_file(test_file)
        
        self.assertIsNotNone(result)
        self.assertTrue(result['new_name'].startswith('00000005'))
    
    def test_parse_with_different_pageaddr(self):
        """测试不同页面地址的计算"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        # 第二个段的起始地址
        pageaddr = XLOG_SEG_SIZE * 1
        create_test_wal_file(test_file, xlp_tli=1, xlp_pageaddr=pageaddr)
        
        result = self.parser.parse_wal_file(test_file)
        
        self.assertIsNotNone(result)
        # 应该是第一个日志文件的第二段
        self.assertEqual(result['logSegNo'], 1)
    
    def test_validate_header_invalid_magic(self):
        """测试魔数验证失败"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        with open(test_file, 'wb') as f:
            header = bytearray(24)
            struct.pack_into("<H", header, 0, 0xFFFF)  # 错误的魔数
            f.write(bytes(header))
        
        result = self.parser.parse_wal_file(test_file)
        self.assertIsNone(result)
    
    def test_validate_header_too_short(self):
        """测试文件头过短"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        with open(test_file, 'wb') as f:
            f.write(b'\x00' * 10)  # 只有 10 字节
        
        result = self.parser.parse_wal_file(test_file)
        self.assertIsNone(result)
    
    def test_file_integrity_check(self):
        """测试文件完整性检查"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        with open(test_file, 'wb') as f:
            f.write(b'\x00' * 10)
        
        valid, msg = self.parser.check_file_integrity(test_file)
        self.assertFalse(valid)
        self.assertIn("太小", msg)
    
    def test_calculate_file_hash(self):
        """测试文件哈希计算"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        create_test_wal_file(test_file)
        
        hash1 = self.parser.calculate_file_hash(test_file)
        hash2 = self.parser.calculate_file_hash(test_file)
        
        self.assertEqual(hash1, hash2)
        self.assertEqual(len(hash1), 64)  # SHA256 十六进制表示


class TestBackupManager(unittest.TestCase):
    """备份管理器测试"""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.logger = StructuredLogger(self.temp_dir, "ERROR")
        self.backup_mgr = BackupManager(self.temp_dir, self.logger)
    
    def tearDown(self):
        shutil.rmtree(self.temp_dir)
    
    def test_record_and_load_state(self):
        """测试状态保存和加载"""
        self.backup_mgr.record_operation("old.wal", "new.wal", "hash123")
        self.backup_mgr.save_state()
        
        state = self.backup_mgr.load_state()
        self.assertEqual(len(state['operations']), 1)
        self.assertEqual(state['operations'][0]['old_name'], "old.wal")
    
    def test_generate_report(self):
        """测试报告生成"""
        self.backup_mgr.record_operation("old1.wal", "new1.wal", "hash1")
        self.backup_mgr.record_operation("old2.wal", "new2.wal", "hash2")
        
        report_file = self.backup_mgr.generate_report()
        
        self.assertTrue(os.path.exists(report_file))
        with open(report_file) as f:
            report = json.load(f)
        self.assertEqual(report['total_operations'], 2)


class TestWALRenamer(unittest.TestCase):
    """WAL 重命名器集成测试"""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.renamer = WALRenamer(self.temp_dir, dry_run=False)
    
    def tearDown(self):
        shutil.rmtree(self.temp_dir)
    
    def test_dry_run_mode(self):
        """测试预览模式"""
        # 创建测试文件
        test_file = os.path.join(self.temp_dir, "wrongname.wal")
        create_test_wal_file(test_file, xlp_tli=1, xlp_pageaddr=0)
        
        # 预览模式
        renamer = WALRenamer(self.temp_dir, dry_run=True)
        renamer.process_directory()
        
        # 文件不应该被重命名
        self.assertTrue(os.path.exists(test_file))
        self.assertEqual(renamer.stats['renamed'], 0)
    
    def test_rename_single_file(self):
        """测试重命名单个文件"""
        # 创建名称错误的 WAL 文件
        old_path = os.path.join(self.temp_dir, "wrongname.wal")
        create_test_wal_file(old_path, xlp_tli=1, xlp_pageaddr=0)
        
        # 执行重命名
        self.renamer.process_directory()
        
        # 检查结果
        expected_name = "000000010000000000000000"
        new_path = os.path.join(self.temp_dir, expected_name)
        
        self.assertFalse(os.path.exists(old_path))
        self.assertTrue(os.path.exists(new_path))
        self.assertEqual(self.renamer.stats['renamed'], 1)
    
    def test_skip_already_correct_names(self):
        """测试跳过已正确命名的文件"""
        # 创建名称正确的文件
        correct_name = "000000010000000000000000"
        file_path = os.path.join(self.temp_dir, correct_name)
        create_test_wal_file(file_path, xlp_tli=1, xlp_pageaddr=0)
        
        self.renamer.process_directory()
        
        # 文件应该保持不变
        self.assertTrue(os.path.exists(file_path))
        self.assertEqual(self.renamer.stats['already_correct'], 1)
        self.assertEqual(self.renamer.stats['renamed'], 0)
    
    def test_handle_target_file_exists(self):
        """测试处理目标文件已存在的情况"""
        # 创建源文件和目标文件
        source_path = os.path.join(self.temp_dir, "source.wal")
        target_name = "000000010000000000000000"
        target_path = os.path.join(self.temp_dir, target_name)
        
        create_test_wal_file(source_path, xlp_tli=1, xlp_pageaddr=0)
        create_test_wal_file(target_path, xlp_tli=1, xlp_pageaddr=0)
        
        self.renamer.process_directory()
        
        # 源文件应该被跳过，目标文件保持不变
        self.assertEqual(self.renamer.stats['skipped'], 1)
        self.assertTrue(os.path.exists(source_path))


class TestEdgeCases(unittest.TestCase):
    """边界情况测试"""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.parser = WALParser()
    
    def tearDown(self):
        shutil.rmtree(self.temp_dir)
    
    def test_non_existent_file(self):
        """测试非存在文件"""
        result = self.parser.parse_wal_file("/non/existent/file.wal")
        self.assertIsNone(result)
    
    def test_empty_file(self):
        """测试空文件"""
        test_file = os.path.join(self.temp_dir, "empty.wal")
        open(test_file, 'wb').close()
        
        result = self.parser.parse_wal_file(test_file)
        self.assertIsNone(result)
    
    def test_very_large_pageaddr(self):
        """测试非常大的页面地址"""
        test_file = os.path.join(self.temp_dir, "test.wal")
        # 非常大的地址（256GB 的位置）
        pageaddr = XLOG_SEG_SIZE * 256 * 256
        create_test_wal_file(test_file, xlp_pageaddr=pageaddr)
        
        result = self.parser.parse_wal_file(test_file)
        self.assertIsNotNone(result)
        # 应该成功计算名称
        self.assertEqual(result['logSegNo'], 256 * 256)


# ============================================================================
# 测试运行器
# ============================================================================
if __name__ == '__main__':
    # 创建测试套件
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    
    # 添加所有测试
    suite.addTests(loader.loadTestsFromTestCase(TestWALParser))
    suite.addTests(loader.loadTestsFromTestCase(TestBackupManager))
    suite.addTests(loader.loadTestsFromTestCase(TestWALRenamer))
    suite.addTests(loader.loadTestsFromTestCase(TestEdgeCases))
    
    # 运行测试
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    
    # 返回适当的退出码
    sys.exit(0 if result.wasSuccessful() else 1)
