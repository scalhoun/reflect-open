import { generateText, isStepCount } from '@reflect/modules/ai'
import { describe, expect, it } from 'vitest'
import { z } from 'zod'
import { createTestIdService, createTestIpcBridgeService } from '../testing/index.ts'
import { createAppleLanguageModel } from './apple-language-model.ts'

function nativeBridge() {
  const ipc = createTestIpcBridgeService()
  ipc.onCommand('apple_language_status', () => ({
    available: true,
    contextWindow: 4096,
    message: 'Ready',
  }))
  return ipc
}
const reply = { text: 'From your notes.', calls: [], inputTokens: 100, outputTokens: 6 }

describe('Apple on-device language model', () => {
  it('runs the SDK tool loop and preserves tool call ids and results across requests', async () => {
    const ipc = nativeBridge()
    let requests = 0
    ipc.onCommand('apple_language_generate', ({ request }) => {
      const parsed = z
        .object({
          messages: z.array(
            z.object({
              role: z.string(),
              calls: z.array(z.object({ id: z.string() })),
              outputs: z.array(z.object({ id: z.string(), text: z.string() })),
            }),
          ),
        })
        .parse(request)
      requests += 1
      if (requests === 1) {
        return {
          ...reply,
          text: '',
          calls: [{ id: 'native-call', name: 'search_notes', input: '{"query":"Aurora"}' }],
        }
      }
      expect(parsed.messages.find((message) => message.role === 'assistant')?.calls).toEqual([
        { id: 'native-call' },
      ])
      expect(parsed.messages.find((message) => message.role === 'tool')?.outputs).toEqual([
        { id: 'native-call', text: '{"title":"Project Aurora","launch":"November 12"}' },
      ])
      return reply
    })
    const queries: string[] = []
    const result = await generateText({
      model: await createAppleLanguageModel({ ipc, id: createTestIdService() }),
      prompt: 'When does Aurora launch?',
      tools: {
        search_notes: {
          inputSchema: z.object({ query: z.string() }),
          execute: ({ query }: { query: string }) => {
            queries.push(query)
            return { title: 'Project Aurora', launch: 'November 12' }
          },
        },
      },
      stopWhen: isStepCount(3),
    })
    expect(result.text).toBe(reply.text)
    expect(queries).toEqual(['Aurora'])
    expect(requests).toBe(2)
    expect(ipc.calls().map((call) => call.command)).toEqual([
      'apple_language_status',
      'apple_language_generate',
      'apple_language_generate',
    ])
  })

  it('reports native unavailability before generation', async () => {
    const ipc = nativeBridge()
    ipc.onCommand('apple_language_status', () => ({
      available: false,
      contextWindow: 4096,
      message: 'Enable Apple Intelligence.',
    }))
    await expect(createAppleLanguageModel({ ipc, id: createTestIdService() })).rejects.toThrow(
      'Enable Apple Intelligence.',
    )
    expect(ipc.calls()).toHaveLength(1)
  })

  it('rejects attachments without passing bytes to native inference', async () => {
    const ipc = nativeBridge()
    const model = await createAppleLanguageModel({ ipc, id: createTestIdService() })
    await expect(
      model.doGenerate({
        prompt: [
          {
            role: 'user',
            content: [{ type: 'file', data: new Uint8Array([1, 2]), mediaType: 'image/png' }],
          },
        ],
      }),
    ).rejects.toThrow('text only')
    expect(ipc.calls()).toHaveLength(1)
  })

  it('validates the native response', async () => {
    const ipc = nativeBridge()
    ipc.onCommand('apple_language_generate', () => ({ text: 'Malformed response' }))
    const model = await createAppleLanguageModel({ ipc, id: createTestIdService() })
    await expect(
      model.doGenerate({ prompt: [{ role: 'user', content: [{ type: 'text', text: 'Hello' }] }] }),
    ).rejects.toThrow('unexpected response shape')
  })

  it('cancels the native task and discards a late reply after abort', async () => {
    const ipc = nativeBridge()
    const abort = new AbortController()
    let finish: (value: typeof reply) => void = () => {
      throw new Error('No pending request')
    }
    ipc.onCommand('apple_language_generate', () => {
      return new Promise<typeof reply>((resolve) => {
        finish = resolve
      })
    })
    ipc.onCommand('apple_language_cancel', () => null)
    const model = await createAppleLanguageModel({ ipc, id: createTestIdService() })
    const pending = model.doGenerate({ prompt: [], abortSignal: abort.signal })
    abort.abort()
    finish(reply)
    await expect(pending).rejects.toThrow()
    const generation = ipc.calls().find((call) => call.command === 'apple_language_generate')
    const id = z.object({ id: z.string() }).parse(generation?.args.request).id
    expect(ipc.calls().find((call) => call.command === 'apple_language_cancel')?.args).toEqual({
      id,
    })
  })
})
