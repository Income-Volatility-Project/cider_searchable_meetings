import { createApp, type WorkerBindings } from './app.ts'
import { createD1Db } from './db/d1.ts'

const app = createApp({
  getDb: (c) => createD1Db(c.env.DB),
})

export default {
  fetch: app.fetch,
} satisfies ExportedHandler<WorkerBindings>
