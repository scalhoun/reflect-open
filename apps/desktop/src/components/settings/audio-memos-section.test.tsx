import { describe, expect, it, vi } from 'vitest'
import { createTestCoreServices } from '@reflect/core/testing'
import { renderInApp } from '@/test-utils/render-in-app.tsx'
import { createWasmTestDatabaseService } from '@/test-utils/test-database.ts'
import { AudioMemosSection } from './audio-memos-section.tsx'

describe('AudioMemosSection', () => {
  it('selects key-free Apple transcription and replaces cloud formatting controls with local model status', async () => {
    const app = createTestCoreServices({ database: createWasmTestDatabaseService() })
    const update = vi.spyOn(app.settings, 'update')
    const view = await renderInApp(<AudioMemosSection />, { app })

    await view.getByRole('radio', { name: 'Apple on-device' }).click()

    expect(update).toHaveBeenCalledWith({ transcriptionEngine: 'apple' })
    await expect
      .element(view.getByRole('combobox', { name: 'Transcription language' }))
      .toBeVisible()
    await expect
      .element(view.getByRole('status'))
      .toHaveTextContent('Ready. Transcription runs on this device.')
    await expect
      .element(view.getByRole('switch', { name: 'Transcription auto-format' }))
      .not.toBeInTheDocument()
  })

  it('explains an unsupported device while keeping the cloud option available', async () => {
    const app = createTestCoreServices({ database: createWasmTestDatabaseService() })
    vi.spyOn(app.transcription, 'appleStatus').mockResolvedValue({
      available: false,
      installed: false,
      locales: [],
      message: 'Apple transcription requires macOS 26 or iOS 26.',
    })
    const view = await renderInApp(<AudioMemosSection />, {
      app,
      settings: { transcriptionEngine: 'apple' },
    })

    await expect
      .element(view.getByRole('status'))
      .toHaveTextContent('Apple transcription requires macOS 26 or iOS 26.')
    await expect.element(view.getByRole('radio', { name: 'OpenAI / Google' })).toBeVisible()
  })
})
