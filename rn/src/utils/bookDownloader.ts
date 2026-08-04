/**
 * 万象书屋 RN · 全本下载管理器
 * 对齐 iOS: BookDownloader
 * 并发下载所有章节正文到本地缓存 (AsyncStorage)
 */

import {getCachedContent, setCachedContent} from './contentCache';
import {fetchProxyContent} from '../api/search';

export type DownloadStatus = 'idle' | 'running' | 'finished' | 'error' | 'cancelled';

export interface DownloadJob {
  bookUrl: string;
  bookName: string;
  origin: string;
  total: number;
  completed: number;
  failed: number;
  status: DownloadStatus;
  startIdx: number;
  endIdx: number;
}

type Listener = (job: DownloadJob) => void;

// 同一本书串行下载（对齐 iOS BookDownloader 的 localConcurrency = 1）：
// 并发拉取同一源的正文会触发源站反爬/RateLimit，导致正文残缺。
const MAX_CONCURRENCY = 1;

class BookDownloader {
  private jobs = new Map<string, DownloadJob>();
  private abortFlags = new Map<string, boolean>();
  private listeners: Listener[] = [];

  subscribe(fn: Listener): () => void {
    this.listeners.push(fn);
    return () => {
      this.listeners = this.listeners.filter(l => l !== fn);
    };
  }

  private emit(job: DownloadJob) {
    this.listeners.forEach(fn => fn({...job}));
  }

  getJob(bookUrl: string): DownloadJob | undefined {
    const j = this.jobs.get(bookUrl);
    return j ? {...j} : undefined;
  }

  getAllJobs(): DownloadJob[] {
    return Array.from(this.jobs.values()).map(j => ({...j}));
  }

  async start(
    bookUrl: string,
    bookName: string,
    origin: string,
    chapters: {url: string; title: string}[],
    startIdx = 0,
    endIdx?: number,
  ): Promise<void> {
    if (this.jobs.get(bookUrl)?.status === 'running') return;

    const end = endIdx ?? chapters.length;
    const slice = chapters.slice(startIdx, end);

    const job: DownloadJob = {
      bookUrl,
      bookName,
      origin,
      total: slice.length,
      completed: 0,
      failed: 0,
      status: 'running',
      startIdx,
      endIdx: end,
    };
    const chapters_ = slice;
    this.jobs.set(bookUrl, job);
    this.abortFlags.set(bookUrl, false);
    this.emit(job);

    let cursor = 0;
    let running = 0;

    // 空章节区间直接结束，避免 Promise 永不 resolve 导致任务卡死在 running
    if (chapters_.length === 0) {
      job.status = 'finished';
      this.emit(job);
      return;
    }

    await new Promise<void>(resolve => {
      const next = () => {
        if (this.abortFlags.get(bookUrl)) {
          if (running === 0) {
            job.status = 'cancelled';
            this.emit(job);
            resolve();
          }
          return;
        }
        while (running < MAX_CONCURRENCY && cursor < chapters_.length) {
          const ch = chapters_[cursor++];
          running++;
          this.downloadOne(origin, ch.url)
            .then(ok => {
              if (ok) job.completed++;
              else job.failed++;
            })
            .catch(() => { job.failed++; })
            .finally(() => {
              running--;
              this.emit(job);
              if (this.abortFlags.get(bookUrl)) {
                // 已取消：在途下载完成后必须收尾为 cancelled，而不是 finished/error
                if (running === 0) {
                  job.status = 'cancelled';
                  this.emit(job);
                  resolve();
                }
              } else if (cursor >= chapters_.length && running === 0) {
                job.status = job.failed > 0 && job.completed === 0 ? 'error' : 'finished';
                this.emit(job);
                resolve();
              } else {
                next();
              }
            });
        }
      };
      next();
    });
  }

  cancel(bookUrl: string) {
    this.abortFlags.set(bookUrl, true);
  }

  private async downloadOne(origin: string, chapterUrl: string): Promise<boolean> {
    const cached = await getCachedContent(origin, chapterUrl);
    if (cached) return true;
    try {
      const content = await fetchProxyContent(origin, chapterUrl);
      if (content) {
        await setCachedContent(origin, chapterUrl, content);
        return true;
      }
      return false;
    } catch {
      return false;
    }
  }
}

export const bookDownloader = new BookDownloader();
