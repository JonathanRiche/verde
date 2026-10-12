import { For, Match, Switch, type JSX } from 'solid-js'

import type { CompanionCharacter, CompanionPose } from '../lib/companion'

/// Vector ports of the desktop characters (packages/desktop/src/ui/companion.zig
/// renderSprout / renderMoss / renderVireo). Same 46-unit geometry; colors are
/// derived live from the theme variables the same way the desktop derives
/// them from accent/text/warning, so every theme recolors the characters.

/// theme.mix(a, b, t): t is the share of `b`.
const mix = (a: string, b: string, t: number) =>
  `color-mix(in srgb, ${a} ${Math.round((1 - t) * 1000) / 10}%, ${b})`
const alpha = (color: string, share: number) => `color-mix(in srgb, ${color} ${share}%, transparent)`

const BG = 'var(--chat-black)'
const TEXT = 'var(--text)'
const ACCENT = 'var(--accent)'
const WARNING = 'var(--warning)'
const DANGER = 'var(--danger)'
const BORDER = 'var(--border)'
const MUTED = 'var(--panel-muted)'
const SHADOW = alpha('#000', 16)

function Box(props: { x: number; y: number; w: number; h: number; r: number; fill: string; stroke?: string }) {
  return (
    <rect
      x={props.x} y={props.y} width={props.w} height={props.h} rx={props.r}
      style={{ fill: props.fill, ...(props.stroke ? { stroke: props.stroke, 'stroke-width': '1' } : {}) }}
    />
  )
}

function Stroke(props: { points: number[][]; color: string; width: number }) {
  return (
    <polyline
      points={props.points.map(([x, y]) => `${x},${y}`).join(' ')}
      style={{ fill: 'none', stroke: props.color, 'stroke-width': String(props.width), 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }}
    />
  )
}

function Sprout(props: { pose: CompanionPose }) {
  const accentHi = mix(ACCENT, TEXT, 0.28)
  const outline = mix(BORDER, ACCENT, 0.55)
  const head = mix(TEXT, accentHi, 0.42)
  const torso = mix(TEXT, accentHi, 0.36)
  const iris = mix(mix(TEXT, DANGER, 0.76), mix(BG, DANGER, 0.66), 0.5)
  const ring = mix(BG, DANGER, 0.4)
  const droop = () => (props.pose === 'paused' ? 4 : 0)
  const gaze = () => (props.pose === 'approval' ? 2 : 0)
  const leaf = () => [[19, 10], [48, 3], [45, 14], [23, 16]].map(([x, y]) => `${x},${y + droop()}`).join(' ')
  return (
    <>
      <Box x={17} y={7} w={3} h={9} r={1.5} fill={mix(BG, ACCENT, 0.85)} />
      <polygon points={leaf()} style={{ fill: mix(ACCENT, accentHi, 0.375) }} />
      <Box x={12} y={38} w={22} h={13} r={6} fill={SHADOW} />
      <Box x={12} y={35} w={22} h={13} r={6} fill={torso} stroke={outline} />
      <Box x={12.5} y={46} w={7} h={4} r={2} fill={mix(TEXT, ACCENT, 0.3)} />
      <Box x={26.5} y={46} w={7} h={4} r={2} fill={mix(TEXT, ACCENT, 0.3)} />
      <Box x={5} y={15} w={36} h={27} r={13} fill={SHADOW} />
      <Box x={5} y={12} w={36} h={27} r={13} fill={head} stroke={outline} />
      <Box x={10} y={15} w={26} h={2} r={1} fill={alpha(TEXT, 25)} />
      <For each={[13, 24.5]}>
        {(x) => (
          <Switch>
            <Match when={props.pose === 'paused'}>
              <Box x={x} y={23} w={8.5} h={2} r={1} fill={mix(DANGER, BG, 0.7)} />
            </Match>
            <Match when={props.pose !== 'paused'}>
              <Box x={x} y={19} w={8.5} h={9} r={4.25} fill={iris} stroke={ring} />
              <Box x={x + 2.5 + gaze()} y={22} w={3.5} h={4} r={1.7} fill={ring} />
              <Box x={x + 1.7} y={20.4} w={3} h={3} r={1.5} fill={mix(DANGER, TEXT, 0.9)} />
              <Box x={x + 5.4} y={24.9} w={1.7} h={1.7} r={0.85} fill={alpha(mix(DANGER, TEXT, 0.7), 80)} />
            </Match>
          </Switch>
        )}
      </For>
      <For each={[-5.5, 0, 5.5]}>
        {(offset) => <Box x={21.5 + offset} y={37} w={3} h={3} r={1.5} fill={mix(MUTED, ACCENT, 0.62)} />}
      </For>
      <Stroke points={[[19.5, 32.5], [23, 34], [26.5, 32.5]]} color={mix(ACCENT, BG, 0.65)} width={1.2} />
    </>
  )
}

function Moss(props: { pose: CompanionPose }) {
  const tone = mix(ACCENT, WARNING, 0.3)
  const body = mix(MUTED, tone, 0.16)
  const outline = mix(BORDER, tone, 0.22)
  const panel = mix(BG, MUTED, 0.55)
  const deep = mix(ACCENT, BG, 0.28)
  const mid = mix(ACCENT, panel, 0.12)
  const lit = mix(mix(ACCENT, TEXT, 0.28), ACCENT, 0.42)
  const d = () => (props.pose === 'paused' ? 1 : 0)
  const hx = () => 14 + (props.pose === 'approval' ? 1.2 : 0)
  const hy = () => 1 + d()
  const gaze = () => (props.pose === 'approval' ? 1.5 : 0)
  return (
    <>
      <Box x={0} y={28} w={46} h={20} r={10} fill={SHADOW} />
      <Box x={0} y={26} w={46} h={20} r={10} fill={body} stroke={outline} />
      <Box x={3} y={43} w={9} h={6} r={4} fill={body} />
      <Box x={34} y={43} w={9} h={6} r={4} fill={body} />
      <Box x={2} y={20 + d()} w={42} h={11} r={6} fill={mid} />
      <Box x={6} y={21 + d()} w={10} h={7} r={4} fill={lit} />
      <Box x={20} y={19 + d()} w={12} h={8} r={5} fill={deep} />
      <Box x={32} y={22 + d()} w={9} h={7} r={4} fill={lit} />
      <Box x={7} y={26 + d()} w={7} h={6} r={3.5} fill={mid} />
      <Box x={31} y={26 + d()} w={9} h={8} r={4} fill={deep} />
      <Box x={8} y={12 + d()} w={1.5} h={8} r={0.8} fill={deep} />
      <Box x={4.5} y={12 + d()} w={5} h={3.5} r={1.8} fill={lit} />
      <Box x={8.5} y={13.5 + d()} w={4} h={3} r={1.5} fill={mid} />
      <Box x={36} y={15 + d()} w={4} h={4} r={2} fill={mix(TEXT, WARNING, 0.18)} />
      <Box x={37} y={16 + d()} w={2} h={2} r={1} fill={WARNING} />
      <Box x={hx() + 6} y={hy() + 17} w={5} h={8} r={2} fill={body} />
      <Box x={hx()} y={hy() + 2} w={17} h={20} r={8.5} fill={SHADOW} />
      <Box x={hx()} y={hy()} w={17} h={20} r={8.5} fill={body} stroke={outline} />
      <Box x={hx() - 3} y={hy() - 2} w={19} h={8} r={4} fill={mid} />
      <Box x={hx() - 1} y={hy() - 1} w={7} h={5} r={2.5} fill={lit} />
      <Box x={hx() + 11} y={hy() + 1} w={6} h={7} r={3} fill={deep} />
      <For each={[3, 9]}>
        {(offset) => (
          <Switch>
            <Match when={props.pose === 'paused'}>
              <Box x={hx() + offset} y={hy() + 8} w={5.5} h={2} r={1} fill={mix(BG, WARNING, 0.35)} />
            </Match>
            <Match when={props.pose !== 'paused'}>
              <Box x={hx() + offset} y={hy() + 6} w={5.5} h={5.5} r={2.75} fill={mix(WARNING, BG, 0.94)} stroke={mix(BG, WARNING, 0.28)} />
              <Box x={hx() + offset + 1.8 + gaze()} y={hy() + 7.8} w={2} h={2} r={1} fill={mix(WARNING, TEXT, 0.22)} />
            </Match>
          </Switch>
        )}
      </For>
      <Box x={hx() + 6} y={hy() + 14.5} w={5} h={2} r={1} fill={mix(BG, WARNING, 0.2)} />
    </>
  )
}

function Vireo(props: { pose: CompanionPose }) {
  const tone = mix(ACCENT, WARNING, 0.45)
  const panel = mix(BG, MUTED, 0.42)
  const olive = mix(tone, panel, 0.42)
  const outline = mix(BORDER, ACCENT, 0.35)
  const brow = mix(TEXT, ACCENT, 0.2)
  const approval = () => props.pose === 'approval'
  const paused = () => props.pose === 'paused'
  const hx = () => 22 + (approval() ? 1.4 : 0)
  const hy = () => 1 + (paused() ? 2 : 0)
  const arc = (points: number[][]) => points.map(([x, y]) => [hx() + x, hy() + y])
  return (
    <>
      <Box x={-9} y={23 + (paused() ? 2 : 0)} w={21} h={5} r={2.5} fill={mix(tone, panel, 0.48)} />
      <Box x={5} y={19} w={33} h={18} r={9} fill={alpha(outline, 16)} />
      <Box x={5} y={17} w={33} h={18} r={9} fill={olive} stroke={outline} />
      <Box x={15} y={25} w={20} h={9} r={5} fill={mix(TEXT, ACCENT, 0.12)} />
      <Box x={18} y={34} w={1.8} h={8} r={0.9} fill={mix(MUTED, BG, 0.3)} />
      <Box x={24.2} y={34} w={1.8} h={8} r={0.9} fill={mix(MUTED, BG, 0.3)} />
      <Box x={6} y={19.5} w={21} h={10} r={5} fill={mix(tone, panel, 0.4)} />
      <Box x={4} y={24.5} w={10} h={4.5} r={2.2} fill={mix(tone, MUTED, 0.65)} />
      <Box x={hx()} y={hy()} w={24} h={16} r={7} fill={mix(olive, panel, 0.18)} stroke={outline} />
      <Box x={hx() + 2} y={hy()} w={18} h={6} r={4} fill={mix(MUTED, BG, 0.26)} />
      <Stroke points={arc([[5.5, 5.8], [10.2, 3.6], [16, 3.3], [22.5, 4.9]])} color={brow} width={1.55} />
      <Stroke points={arc([[6, 7.2], [10.6, 5.4], [16.2, 5.2], [21.8, 6.6]])} color={mix(BG, WARNING, 0.28)} width={1.15} />
      <Switch>
        <Match when={paused()}>
          <Box x={hx() + 14.5} y={hy() + 6.7} w={5.5} h={2.5} r={1.2} fill={mix(BG, DANGER, 0.3)} />
        </Match>
        <Match when={!paused()}>
          <Box x={hx() + 14.5} y={hy() + 6.7} w={5.5} h={5.5} r={2.75} fill={mix(DANGER, TEXT, 0.12)} stroke={brow} />
          <Box
            x={hx() + 14.5 + 0.55 + (approval() ? 0.85 : 0)}
            y={hy() + 6.7 + 1.55 + (approval() ? 0.45 : 0)}
            w={2.2} h={2.2} r={1.1} fill={BG}
          />
        </Match>
      </Switch>
      <Box x={hx() + 21} y={hy() + 7} w={10} h={3} r={1.5} fill={mix(BG, MUTED, 0.22)} />
    </>
  )
}

/// Each character's drawn extent (the desktop rect plus overhang: Sprout's
/// leaf, Moss's crown moss, Vireo's tail and beak).
const VIEW_BOX: Record<CompanionCharacter, string> = {
  sprout: '-1 0 50 52',
  moss: '-2 -2 50 52',
  vireo: '-10 -1 66 46',
}

export function CompanionAvatar(props: {
  character: CompanionCharacter
  pose: CompanionPose
  class?: string
  /// Accessible name; omitted when a neighboring label already names it.
  label?: string
}): JSX.Element {
  return (
    <svg
      class={`companion-avatar shrink-0 overflow-visible ${props.class ?? 'h-10 w-10'}`}
      viewBox={VIEW_BOX[props.character]}
      role={props.label ? 'img' : undefined}
      aria-label={props.label}
      aria-hidden={props.label ? undefined : 'true'}
      data-pose={props.pose}
    >
      <g class="companion-figure">
        <Switch>
          <Match when={props.character === 'moss'}><Moss pose={props.pose} /></Match>
          <Match when={props.character === 'vireo'}><Vireo pose={props.pose} /></Match>
          <Match when={true}><Sprout pose={props.pose} /></Match>
        </Switch>
      </g>
    </svg>
  )
}
