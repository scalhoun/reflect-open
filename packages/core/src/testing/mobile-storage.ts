import type { GraphInfo } from '../graph/schemas.ts'
import type { MobileStorageInfo, MobileStorageService } from '../ipc/mobile-storage-service.ts'

export interface TestMobileStorageServiceOptions {
  /**
   * The folder selected by the picker, or null for cancellation.
   */
  selectedFolder?: string | null
  /**
   * The folder restored from a saved bookmark.
   */
  restoredFolder?: string | null
  /**
   * What `resolve` answers. Defaults to a local-only device.
   */
  storage?: MobileStorageInfo
}

export interface TestMobileStorageService extends MobileStorageService {
  /**
   * Changes subsequent picker results.
   */
  setSelectedFolder(path: string | null): void
  /**
   * Whether each pending grant was committed or cancelled.
   */
  finishedSelections(): readonly boolean[]
  /**
   * The path of every `createGraph`, in order.
   */
  createdGraphs(): readonly string[]
}

function baseName(path: string): string {
  return path.split('/').findLast((segment) => segment !== '') ?? path
}

class TestMobileStorageServiceImpl implements TestMobileStorageService {
  readonly #storage: MobileStorageInfo
  readonly #created: string[] = []
  #selectedFolder: string | null
  #restoredFolder: string | null
  readonly #finished: boolean[] = []

  constructor(options?: TestMobileStorageServiceOptions) {
    this.#selectedFolder = options?.selectedFolder ?? null
    this.#restoredFolder = options?.restoredFolder ?? null
    this.#storage = options?.storage ?? {
      localRoot: '/local/Documents',
      icloudDocumentsRoot: null,
      icloudGraphRoots: [],
    }
  }

  pickFolder(): Promise<string | null> {
    return Promise.resolve(this.#selectedFolder)
  }
  resolveFolder(): Promise<string | null> {
    return Promise.resolve(this.#restoredFolder)
  }
  finishFolderSelection(commit: boolean): Promise<void> {
    this.#finished.push(commit)
    if (commit) this.#restoredFolder = this.#selectedFolder
    return Promise.resolve()
  }
  releaseFolder(): Promise<void> {
    return Promise.resolve()
  }
  setSelectedFolder(path: string | null): void {
    this.#selectedFolder = path
  }
  finishedSelections(): readonly boolean[] {
    return [...this.#finished]
  }

  resolve(): Promise<MobileStorageInfo> {
    return Promise.resolve({
      ...this.#storage,
      icloudGraphRoots: [...this.#storage.icloudGraphRoots],
    })
  }

  resolveLocal(): Promise<string> {
    return Promise.resolve(this.#storage.localRoot)
  }

  createGraph(path: string): Promise<GraphInfo> {
    this.#created.push(path)
    return Promise.resolve({ root: path, name: baseName(path), generation: 1 })
  }

  createdGraphs(): readonly string[] {
    return [...this.#created]
  }
}

/**
 * An in-memory {@link MobileStorageService}. `createGraph` answers a graph
 * named after the last path segment, with generation `1`.
 */
export function createTestMobileStorageService(
  options?: TestMobileStorageServiceOptions,
): TestMobileStorageService {
  return new TestMobileStorageServiceImpl(options)
}
