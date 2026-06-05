import { useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import type { OpenAICompatibleSettings } from "@/lib/settings";
import type { OpenAIProxySecretStatus } from "@/hooks/app/use-openai-compatible-settings";

const inputClassName = "h-8 w-full rounded-md border border-input bg-background px-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50";

function parsePrice(value: string): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
}

export function OpenAICompatibleSettingsSection({
  settings,
  secretStatus,
  localToken,
  onSettingsChange,
  onUpstreamKeySave,
  onLocalTokenReveal,
  onLocalTokenCopy,
  onLocalTokenRegenerate,
}: {
  settings: OpenAICompatibleSettings;
  secretStatus: OpenAIProxySecretStatus;
  localToken: string | null;
  onSettingsChange: (value: OpenAICompatibleSettings) => void;
  onUpstreamKeySave: (value: string) => void;
  onLocalTokenReveal: () => void;
  onLocalTokenCopy: () => void;
  onLocalTokenRegenerate: () => void;
}) {
  const [upstreamKey, setUpstreamKey] = useState("");
  const safeSecretStatus = secretStatus ?? { hasUpstreamKey: false, hasLocalToken: false };

  const updatePrice = (
    index: number,
    patch: Partial<OpenAICompatibleSettings["prices"][number]>
  ) => {
    onSettingsChange({
      ...settings,
      prices: settings.prices.map((price, i) => i === index ? { ...price, ...patch } : price),
    });
  };

  return (
    <section>
      <h3 className="text-lg font-semibold mb-0">OpenAI Compatible</h3>
      <p className="text-sm text-muted-foreground mb-2">Local proxy at 127.0.0.1:6737/v1</p>
      <div className="bg-muted/50 rounded-lg p-2 space-y-3">
        <label className="flex items-center gap-2 text-sm select-none text-foreground">
          <Checkbox
            key={`openai-compatible-enabled-${settings.enabled}`}
            checked={settings.enabled}
            onCheckedChange={(checked) => onSettingsChange({ ...settings, enabled: checked === true })}
          />
          Enable proxy
        </label>

        <label className="block space-y-1 text-sm">
          <span>Endpoint</span>
          <input
            aria-label="Endpoint"
            className={inputClassName}
            value={settings.endpoint}
            placeholder="https://api.example.com/v1"
            onChange={(event) => onSettingsChange({ ...settings, endpoint: event.currentTarget.value })}
          />
        </label>

        <div className="grid grid-cols-[1fr_auto] gap-2 items-end">
          <label className="block space-y-1 text-sm">
            <span>Upstream API key</span>
            <input
              aria-label="Upstream API key"
              className={inputClassName}
              type="password"
              value={upstreamKey}
              placeholder={safeSecretStatus.hasUpstreamKey ? "Saved" : "sk-..."}
              onChange={(event) => setUpstreamKey(event.currentTarget.value)}
            />
          </label>
          <Button
            type="button"
            size="sm"
            onClick={() => {
              onUpstreamKeySave(upstreamKey);
              setUpstreamKey("");
            }}
          >
            Save key
          </Button>
        </div>

        <div className="grid grid-cols-[1fr_auto_auto_auto] gap-2 items-end">
          <label className="block space-y-1 text-sm">
            <span>Local token</span>
            <input
              aria-label="Local token"
              className={inputClassName}
              readOnly
              value={localToken ?? (safeSecretStatus.hasLocalToken ? "Saved" : "")}
              placeholder="Generate before use"
            />
          </label>
          <Button type="button" size="sm" variant="outline" onClick={onLocalTokenReveal}>
            Show token
          </Button>
          <Button type="button" size="sm" variant="outline" onClick={onLocalTokenCopy}>
            Copy token
          </Button>
          <Button type="button" size="sm" variant="outline" onClick={onLocalTokenRegenerate}>
            Regenerate token
          </Button>
        </div>

        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium">Model prices</span>
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() =>
                onSettingsChange({
                  ...settings,
                  prices: [
                    ...settings.prices,
                    { modelName: "", inputUsdPer1M: 0, outputUsdPer1M: 0 },
                  ],
                })
              }
            >
              <Plus className="h-4 w-4" />
            </Button>
          </div>
          {settings.prices.map((price, index) => {
            const nameLabel = price.modelName || `row ${index + 1}`;
            return (
              <div key={index} className="grid grid-cols-[1.2fr_0.8fr_0.8fr_auto] gap-2 items-end">
                <label className="block space-y-1 text-xs">
                  <span>Model</span>
                  <input
                    aria-label={`Model name ${index + 1}`}
                    className={inputClassName}
                    value={price.modelName}
                    onChange={(event) => updatePrice(index, { modelName: event.currentTarget.value })}
                  />
                </label>
                <label className="block space-y-1 text-xs">
                  <span>Input / 1M</span>
                  <input
                    aria-label={`Input price for ${nameLabel}`}
                    className={inputClassName}
                    inputMode="decimal"
                    value={String(price.inputUsdPer1M)}
                    onChange={(event) => updatePrice(index, { inputUsdPer1M: parsePrice(event.currentTarget.value) })}
                  />
                </label>
                <label className="block space-y-1 text-xs">
                  <span>Output / 1M</span>
                  <input
                    aria-label={`Output price for ${nameLabel}`}
                    className={inputClassName}
                    inputMode="decimal"
                    value={String(price.outputUsdPer1M)}
                    onChange={(event) => updatePrice(index, { outputUsdPer1M: parsePrice(event.currentTarget.value) })}
                  />
                </label>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  aria-label={`Remove ${nameLabel}`}
                  onClick={() => onSettingsChange({
                    ...settings,
                    prices: settings.prices.filter((_, i) => i !== index),
                  })}
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
