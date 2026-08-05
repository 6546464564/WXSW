/**
 * 万象书屋 RN · BookDownloader 全本下载测试
 * 覆盖: 下载成功 / 部分失败 / 全部失败 → error / 空区间 / 取消 / 重复启动去重
 */

jest.mock('../src/api/search', () => ({
  fetchProxyContent: jest.fn(),
}));

import {fetchProxyContent} from '../src/api/search';
import {bookDownloader} from '../src/utils/bookDownloader';
import AsyncStorage from '@react-native-async-storage/async-storage';

const mockedFetch = fetchProxyContent as jest.Mock;

const chapters = (n: number) =>
  Array.from({length: n}, (_, i) => ({
    url: `https://x.com/ch/${i + 1}`,
    title: `第${i + 1}章`,
  }));

describe('bookDownloader', () => {
  beforeEach(async () => {
    await AsyncStorage.clear();
    mockedFetch.mockReset();
  });

  test('全部成功 → finished, completed=total', async () => {
    mockedFetch.mockResolvedValue('正文内容');
    const listener = jest.fn();
    bookDownloader.subscribe(listener);

    await bookDownloader.start('book-1', '书一', 'src', chapters(3));

    expect(mockedFetch).toHaveBeenCalledTimes(3);
    const job = bookDownloader.getJob('book-1')!;
    expect(job.status).toBe('finished');
    expect(job.completed).toBe(3);
    expect(job.failed).toBe(0);
  });

  test('部分成功部分失败 → finished (非全败), failed 计数正确', async () => {
    mockedFetch.mockImplementation((origin: string, url: string) =>
      url.endsWith('/1') ? Promise.resolve('内容') : Promise.resolve(''),
    );
    await bookDownloader.start('book-2', '书二', 'src', chapters(3));
    const job = bookDownloader.getJob('book-2')!;
    expect(job.status).toBe('finished');
    expect(job.completed).toBe(1);
    expect(job.failed).toBe(2);
  });

  test('全部失败 → error', async () => {
    mockedFetch.mockRejectedValue(new Error('network'));
    await bookDownloader.start('book-3', '书三', 'src', chapters(2));
    const job = bookDownloader.getJob('book-3')!;
    expect(job.status).toBe('error');
    expect(job.failed).toBe(2);
    expect(job.completed).toBe(0);
  });

  test('空章节区间 → 直接 finished', async () => {
    await bookDownloader.start('book-4', '书四', 'src', [], 0, 0);
    const job = bookDownloader.getJob('book-4')!;
    expect(job.status).toBe('finished');
    expect(job.total).toBe(0);
    expect(mockedFetch).not.toHaveBeenCalled();
  });

  test('startIdx/endIdx 切片', async () => {
    mockedFetch.mockResolvedValue('内容');
    await bookDownloader.start('book-5', '书五', 'src', chapters(10), 3, 6);
    const job = bookDownloader.getJob('book-5')!;
    expect(job.total).toBe(3);
    expect(job.startIdx).toBe(3);
    expect(job.endIdx).toBe(6);
    expect(job.completed).toBe(3);
  });

  test('运行中重复 start 去重 (不叠加)', async () => {
    mockedFetch.mockImplementation(() => new Promise(resolve => setTimeout(() => resolve('x'), 30)));
    const p1 = bookDownloader.start('book-6', '书六', 'src', chapters(5));
    const p2 = bookDownloader.start('book-6', '书六', 'src', chapters(5));
    await Promise.all([p1, p2]);
    // 5 章只应下载 5 次 (第二次 start 直接 return)
    expect(mockedFetch).toHaveBeenCalledTimes(5);
  });

  test('取消 → cancelled', async () => {
    mockedFetch.mockImplementation(() => new Promise(resolve => setTimeout(() => resolve('x'), 20)));
    const p = bookDownloader.start('book-7', '书七', 'src', chapters(5));
    await new Promise(r => setTimeout(r, 5));
    bookDownloader.cancel('book-7');
    await p;
    const job = bookDownloader.getJob('book-7')!;
    expect(job.status).toBe('cancelled');
  });

  test('缓存命中时不再请求网络 (downloadOne 走缓存)', async () => {
    mockedFetch.mockResolvedValue('内容');
    // 预先写缓存
    const {setCachedContent} = require('../src/utils/contentCache');
    await setCachedContent('src', 'https://x.com/ch/1', '已缓存正文');

    await bookDownloader.start('book-8', '书八', 'src', chapters(2));
    expect(mockedFetch).toHaveBeenCalledTimes(1); // 只有 ch/2 走网络
    const job = bookDownloader.getJob('book-8')!;
    expect(job.completed).toBe(2);
  });

  test('subscribe 退订后不再收到事件', async () => {
    mockedFetch.mockResolvedValue('内容');
    const listener = jest.fn();
    const unsub = bookDownloader.subscribe(listener);
    await bookDownloader.start('book-9', '书九', 'src', chapters(1));
    expect(listener).toHaveBeenCalled();
    unsub();
    mockedFetch.mockResolvedValue('内容');
    await bookDownloader.start('book-10', '书十', 'src', chapters(1));
    const calls = listener.mock.calls.length;
    await new Promise(r => setTimeout(r, 30));
    expect(listener.mock.calls.length).toBe(calls);
  });
});
