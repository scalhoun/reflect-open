import type {
  LanguageModelV3,
  LanguageModelV3CallOptions,
  LanguageModelV3GenerateResult,
  LanguageModelV3StreamPart,
} from '@ai-sdk/provider'
import { z } from 'zod'
import type { IpcBridgeService } from '../ipc/ipc-service.ts'
import type { IdService } from '../ports/id-service.ts'
import { AppError } from '../errors.ts'

const statusSchema = z.object({
  available: z.boolean(),
  message: z.string(),
  contextWindow: z.number().int().positive(),
})
const replySchema = z.object({
  text: z.string(),
  calls: z.array(z.object({ id: z.string(), name: z.string(), input: z.string() })),
  inputTokens: z.number().int().nonnegative(),
  outputTokens: z.number().int().nonnegative().nullish(),
})

interface AppleModelDeps {
  readonly ipc: IpcBridgeService
  readonly id: IdService
}
interface NativeCall {
  id: string
  name: string
  input: string
}
interface NativeOutput {
  id: string
  name: string
  text: string
}
interface NativeMessage {
  role: string
  text: string
  calls: NativeCall[]
  outputs: NativeOutput[]
}

function nativeMessages(prompt: LanguageModelV3CallOptions['prompt']): NativeMessage[] {
  return prompt.map((message) => {
    const result: NativeMessage = { role: message.role, text: '', calls: [], outputs: [] }
    if (message.role === 'system') {
      result.text = message.content
      return result
    }
    for (const part of message.content) {
      switch (part.type) {
        case 'text':
          result.text += part.text
          break
        case 'tool-call':
          result.calls.push({
            id: part.toolCallId,
            name: part.toolName,
            input: JSON.stringify(part.input),
          })
          break
        case 'tool-result': {
          const output = part.output
          if (output.type === 'content') {
            throw new AppError('io', 'Apple local AI supports text tool results only.')
          }
          result.outputs.push({
            id: part.toolCallId,
            name: part.toolName,
            text:
              output.type === 'execution-denied'
                ? (output.reason ?? 'Tool execution denied.')
                : typeof output.value === 'string'
                  ? output.value
                  : JSON.stringify(output.value),
          })
          break
        }
        case 'reasoning':
          break
        default:
          throw new AppError(
            'io',
            'Apple local AI supports text only. Remove image or file attachments to continue.',
          )
      }
    }
    return result
  })
}

/**
 * An AI SDK model backed exclusively by Apple's on-device Foundation Models framework.
 * Tool calls return to the normal host executors, including their privacy checks.
 */
export async function createAppleLanguageModel(deps: AppleModelDeps): Promise<LanguageModelV3> {
  const status = await deps.ipc.call('apple_language_status', {}, statusSchema)
  if (!status.available) {
    throw new AppError('io', status.message)
  }
  const generate = async (
    options: LanguageModelV3CallOptions,
  ): Promise<LanguageModelV3GenerateResult> => {
    options.abortSignal?.throwIfAborted()
    if (options.responseFormat?.type === 'json') {
      throw new AppError('io', 'Apple local AI currently supports text responses only.')
    }
    const choice = options.toolChoice
    const tools = (options.tools ?? [])
      .map((tool) => {
        if (tool.type !== 'function') {
          throw new AppError('io', 'Apple local AI supports host function tools only.')
        }
        return {
          name: tool.name,
          description: tool.description ?? '',
          parameters: tool.inputSchema,
        }
      })
      .filter((tool) => choice?.type !== 'tool' || tool.name === choice.toolName)
    const id = deps.id.uuid()
    const request = {
      id,
      messages: nativeMessages(options.prompt),
      tools,
      toolChoice: choice?.type === 'tool' ? 'required' : (choice?.type ?? 'auto'),
      maxOutputTokens: Math.min(options.maxOutputTokens ?? 512, 512),
    }
    const cancel = (): void => {
      void deps.ipc.call('apple_language_cancel', { id }, z.null()).catch(() => {})
    }
    options.abortSignal?.addEventListener('abort', cancel, { once: true })
    try {
      options.abortSignal?.throwIfAborted()
      const reply = await deps.ipc.call('apple_language_generate', { request }, replySchema)
      options.abortSignal?.throwIfAborted()
      return {
        content: [
          ...(reply.text === '' ? [] : [{ type: 'text' as const, text: reply.text }]),
          ...reply.calls.map((call) => ({
            type: 'tool-call' as const,
            toolCallId: call.id,
            toolName: call.name,
            input: call.input,
          })),
        ],
        finishReason: { unified: reply.calls.length > 0 ? 'tool-calls' : 'stop', raw: undefined },
        usage: {
          inputTokens: {
            total: reply.inputTokens,
            noCache: reply.inputTokens,
            cacheRead: undefined,
            cacheWrite: undefined,
          },
          outputTokens: {
            total: reply.outputTokens ?? undefined,
            text: reply.outputTokens ?? undefined,
            reasoning: undefined,
          },
        },
        warnings: [],
      }
    } finally {
      options.abortSignal?.removeEventListener('abort', cancel)
    }
  }
  return {
    specificationVersion: 'v3',
    provider: 'apple',
    modelId: 'apple-system',
    supportedUrls: {},
    doGenerate: generate,
    doStream: async (options) => {
      const reply = await generate(options)
      return {
        stream: new ReadableStream<LanguageModelV3StreamPart>({
          start(controller) {
            controller.enqueue({ type: 'stream-start', warnings: [] })
            for (const part of reply.content) {
              if (part.type === 'text') {
                controller.enqueue({ type: 'text-start', id: 'apple-reply' })
                controller.enqueue({ type: 'text-delta', id: 'apple-reply', delta: part.text })
                controller.enqueue({ type: 'text-end', id: 'apple-reply' })
              } else if (part.type === 'tool-call') {
                controller.enqueue(part)
              }
            }
            controller.enqueue({
              type: 'finish',
              finishReason: reply.finishReason,
              usage: reply.usage,
            })
            controller.close()
          },
        }),
      }
    },
  }
}
