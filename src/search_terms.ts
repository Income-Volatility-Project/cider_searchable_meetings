import type { Db } from './db/local.ts'

export function refreshSearchTerms(db: Db): void {
  db.transaction(() => {
    db.run('DELETE FROM search_terms')
    db.run(
      `
      INSERT INTO search_terms (term, doc_count)
      SELECT term, sum(doc) AS doc_count
      FROM (
        SELECT term, doc FROM meetings_vocab
        UNION ALL
        SELECT term, doc FROM utterances_vocab
      )
      WHERE length(term) >= 3
        AND term GLOB '*[A-Za-z]*'
      GROUP BY term
      `,
    )

    db.run('DELETE FROM search_terms_trigram')
    db.run('INSERT INTO search_terms_trigram (term) SELECT term FROM search_terms')
  })
}
