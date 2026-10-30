/** Persistent "already processed" set of event ids (outbox redelivery after a crash is processed once). */

import { appendLine, readText, writeFileAtomic } from '../util/fs.js'

export class SeenEvents {
  private readonly order: string[] = []
  private readonly set = new Set<string>()
  private appended = 0

  constructor(private readonly file: string, private readonly max = 5000) {}

  async load(): Promise<void> {
    const text = await readText(this.file)
    if (text === undefined) return
    for (const line of text.split('\n')) {
      const id = line.trim()
      if (id !== '' && !this.set.has(id)) {
        this.set.add(id)
        this.order.push(id)
      }
    }
    this.trim()
  }

  has(eventId: string): boolean {
    return this.set.has(eventId)
  }

  async add(eventId: string): Promise<void> {
    if (this.set.has(eventId)) return
    this.set.add(eventId)
    this.order.push(eventId)
    this.appended += 1
    if (this.trim() || this.appended > this.max) {
      this.appended = 0
      await writeFileAtomic(this.file, `${this.order.join('\n')}\n`)
    } else {
      await appendLine(this.file, eventId)
    }
  }

  private trim(): boolean {
    if (this.order.length <= this.max) return false
    for (const id of this.order.splice(0, this.order.length - this.max)) this.set.delete(id)
    return true
  }
}
