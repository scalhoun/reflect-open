import type { ReactElement } from 'react'
import {
  TRANSCRIPTION_PROMPT_MAX_LENGTH,
  errorMessage,
  normalizeTranscriptionPrompt,
  transcriptionLanguageSchema,
} from '@reflect/core'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select.tsx'
import { useAppleSpeechStatus } from '@/hooks/use-apple-speech-status.ts'
import { useSettings } from '@/providers/settings-provider.tsx'
import { SettingsField } from './field.tsx'
import { SettingsOptionCard } from './option-card.tsx'
import { SettingsSection } from './section.tsx'
import { SettingsSwitchField } from './switch-field.tsx'
import { SettingsTextareaField } from './textarea-field.tsx'

/** Preferences for recording enrichment after the raw audio is safely stored. */
export function AudioMemosSection(): ReactElement {
  const { settings, updateSettings } = useSettings()
  const status = useAppleSpeechStatus(settings.transcriptionLanguage)
  const apple = settings.transcriptionEngine === 'apple'
  const languages =
    status.data?.locales.map((locale) => {
      const value = locale.replaceAll('_', '-')
      return {
        value,
        label: new Intl.DisplayNames(['en'], { type: 'language' }).of(value) ?? value,
      }
    }) ?? []
  const engines = [
    { value: 'cloud', label: 'OpenAI / Google' },
    { value: 'apple', label: 'Apple on-device' },
  ] as const

  return (
    <SettingsSection id="audio-memos">
      <SettingsField
        legend="Transcription engine"
        description="Apple transcribes on this device without an API key. OpenAI and Google use your configured key."
      >
        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          {engines.map((engine) => (
            <SettingsOptionCard
              key={engine.value}
              selected={settings.transcriptionEngine === engine.value}
              className="items-center gap-2.5 px-3 py-2.5"
            >
              <input
                type="radio"
                name="transcription-engine"
                value={engine.value}
                checked={settings.transcriptionEngine === engine.value}
                onChange={() => updateSettings({ transcriptionEngine: engine.value })}
                className="accent-accent"
              />
              <span className="text-sm text-text">{engine.label}</span>
            </SettingsOptionCard>
          ))}
        </div>
      </SettingsField>
      {apple && (
        <SettingsField
          legend="Transcription language"
          description="Choose the language you speak. Missing Apple models download automatically on the first recording."
        >
          <div className="mt-3">
            <Select
              value={settings.transcriptionLanguage}
              items={languages}
              disabled={languages.length === 0}
              onValueChange={(value) => {
                updateSettings({ transcriptionLanguage: transcriptionLanguageSchema.parse(value) })
              }}
            >
              <SelectTrigger aria-label="Transcription language" className="w-64">
                <SelectValue placeholder={settings.transcriptionLanguage} />
              </SelectTrigger>
              <SelectContent>
                {languages.map((language) => (
                  <SelectItem key={language.value} value={language.value}>
                    {language.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p role="status" className="mt-2 text-xs text-text-muted">
              {status.isPending
                ? 'Checking Apple transcription…'
                : status.isError
                  ? errorMessage(status.error)
                  : status.data.available
                    ? status.data.installed
                      ? 'Ready. Transcription runs on this device.'
                      : 'Available. The language model will download when you record.'
                    : status.data.message}
            </p>
            <p className="mt-1 text-xs text-text-muted">
              Apple supplies punctuation. Titles use the first words of your transcript, with no
              cloud formatting or title generation.
            </p>
          </div>
        </SettingsField>
      )}
      {!apple && (
        <>
          <SettingsSwitchField
            legend="Transcription auto-format"
            description="Use AI to add punctuation, paragraphs, and light Markdown while preserving the original meaning."
            checked={settings.transcriptionFormat}
            onCheckedChange={(transcriptionFormat) => updateSettings({ transcriptionFormat })}
          />
          <SettingsTextareaField
            legend="Transcription helper text"
            description="Context sent to your transcription provider with every audio memo, such as names it tends to misspell."
            ariaLabel="Transcription helper text"
            value={settings.transcriptionPrompt}
            placeholder="This transcription mentions the following names:"
            maxLength={TRANSCRIPTION_PROMPT_MAX_LENGTH}
            rows={2}
            normalize={normalizeTranscriptionPrompt}
            onSave={(transcriptionPrompt) => updateSettings({ transcriptionPrompt })}
          />
        </>
      )}
    </SettingsSection>
  )
}
