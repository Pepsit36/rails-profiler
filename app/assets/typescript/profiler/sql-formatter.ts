// SQL syntax highlighting and formatting

const SQL_KEYWORDS = [
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'UPDATE', 'DELETE', 'JOIN', 'LEFT', 'RIGHT',
  'INNER', 'OUTER', 'ON', 'AS', 'AND', 'OR', 'NOT', 'IN', 'EXISTS', 'LIKE',
  'ORDER', 'BY', 'GROUP', 'HAVING', 'LIMIT', 'OFFSET', 'DISTINCT', 'COUNT',
  'SUM', 'AVG', 'MAX', 'MIN', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END'
];

export function formatSQL(element: HTMLElement): void {
  const sql = element.textContent || '';
  const formatted = highlightSQL(sql);
  element.innerHTML = formatted;
}

function highlightSQL(sql: string): string {
  let highlighted = sql;

  // Highlight keywords
  SQL_KEYWORDS.forEach(keyword => {
    const regex = new RegExp(`\\b${keyword}\\b`, 'gi');
    highlighted = highlighted.replace(regex, `<span class="sql-keyword">${keyword}</span>`);
  });

  // Highlight strings
  highlighted = highlighted.replace(/'([^']*)'/g, '<span class="sql-string">\'$1\'</span>');

  // Highlight numbers
  highlighted = highlighted.replace(/\b(\d+)\b/g, '<span class="sql-number">$1</span>');

  // Highlight comments
  highlighted = highlighted.replace(/--([^\n]*)/g, '<span class="sql-comment">--$1</span>');

  return highlighted;
}

export function prettifySQL(sql: string): string {
  let pretty = sql;

  // Add newlines after major keywords
  const newlineKeywords = ['SELECT', 'FROM', 'WHERE', 'JOIN', 'ORDER BY', 'GROUP BY'];
  newlineKeywords.forEach(keyword => {
    const regex = new RegExp(`\\b${keyword}\\b`, 'gi');
    pretty = pretty.replace(regex, `\n${keyword}`);
  });

  // Indent
  const lines = pretty.split('\n');
  return lines.map((line, index) => {
    if (index === 0) return line.trim();
    return '  ' + line.trim();
  }).join('\n');
}
