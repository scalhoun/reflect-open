import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import type { AppleSpeechStatus } from '@reflect/core'
import { useCoreServices } from '@/services/services-provider.tsx'

/**
 * Refresh device and model availability when the selected speech language changes.
 */
export function useAppleSpeechStatus(locale: string): UseQueryResult<AppleSpeechStatus> {
  const { transcription } = useCoreServices()
  return useQuery({
    queryKey: ['apple-speech-status', locale],
    queryFn: () => transcription.appleStatus(locale),
  })
}
