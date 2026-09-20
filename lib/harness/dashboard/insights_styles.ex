defmodule Harness.Dashboard.InsightsStyles do
  @moduledoc "Scoped Run Insights layout using the dashboard's existing tokens."
  use Phoenix.Component

  @doc "Renders feature-scoped layout and control styles."
  @spec styles(map()) :: Phoenix.LiveView.Rendered.t()
  def styles(assigns) do
    ~H"""
    <style>
      .insights { overflow-wrap: anywhere; }
      .insights h1 { margin: 0; }
      .insights h2 { font-size: var(--text-lg); margin: 0 0 var(--space-3); color: var(--text); }
      .insights h3 {
        margin: var(--space-4) 0 var(--space-2);
        font-size: var(--text-md);
        color: var(--text);
      }
      .insights p { max-width: 72ch; line-height: 1.65; margin: var(--space-2) 0; }
      .insights .insights-prose { white-space: pre-line; }
      .insights .insights-header, .insights .insights-toolbar, .insights .insights-actions {
        display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--space-3);
      }
      .insights .insights-header { margin-bottom: var(--space-6); }
      .insights .insights-actions { justify-content: flex-start; }
      .insights .btn-save, .insights .btn-dispatch {
        min-height: 44px; display: inline-flex; align-items: center; text-decoration: none; box-sizing: border-box;
      }
      .insights button:disabled { opacity: .5; cursor: not-allowed; }
      .insights .insights-meta { color: var(--text-subtle); font-size: var(--text-sm); }
      .insights .insights-panel {
        padding: var(--space-5); background: var(--surface); border: 1px solid var(--rule);
        border-radius: .5rem; margin-bottom: var(--space-6);
      }
      .insights .insights-panel[data-state="disabled"] h2 { color: var(--text-muted); }
      .insights .insights-panel[data-state="observing"] h2 { color: var(--accent); }
      .insights .insights-panel[data-state="failed"] h2 { color: var(--verdict-fail); }
      .insights .insights-panel[data-state="successful"] h2,
      .insights .insights-panel[data-state="no_findings"] h2 { color: var(--verdict-pass); }
      .insights .insights-summary {
        display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: var(--space-4) var(--space-6); margin: var(--space-4) 0 0;
      }
      .insights dt {
        color: var(--text-muted); font-size: var(--text-xs); margin-bottom: var(--space-1);
        letter-spacing: 0.04em; text-transform: uppercase; font-weight: 600;
      }
      .insights dd { margin: 0; font-family: var(--font-mono); font-size: var(--text-sm); }
      .insights .insights-toolbar { padding-bottom: var(--space-4); border-bottom: 1px solid var(--rule); }
      .insights .insights-toolbar h2 { margin: 0; }
      .insights form { margin: 0; }
      .insights .insights-fields {
        display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: var(--space-5); margin: var(--space-5) 0;
      }
      .insights .insights-field { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
      .insights label { font-weight: 600; font-size: var(--text-sm); }
      .insights select {
        width: 100%; min-height: 44px; background: var(--surface-2); color: var(--text);
        border: 1px solid var(--rule-strong); border-radius: .35rem;
        padding: var(--space-2) calc(var(--space-3) + 1rem) var(--space-2) var(--space-3);
        font: inherit; appearance: none; -webkit-appearance: none;
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%238a90a0' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
        background-repeat: no-repeat; background-position: right var(--space-3) center;
      }
      .insights :is(a, button, select, summary):focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
      .insights .insights-empty { padding: var(--space-6) 0; }
      .insights .insights-empty .insights-actions { margin-top: var(--space-4); }
      .insights .insights-row { padding: var(--space-5) 0; border-bottom: 1px solid var(--rule); }
      .insights .insights-row h2 a { color: var(--text); text-decoration: none; }
      .insights .insights-row h2 a:hover { color: var(--accent); }
      .insights .insights-notice {
        padding: var(--space-3) var(--space-4); margin-bottom: var(--space-4);
        background: var(--surface-2); border: 1px solid var(--rule); border-radius: .35rem;
      }
      .insights [role=alert] { color: var(--accent); }
      .insights .insights-history { list-style: none; padding: 0; margin: var(--space-4) 0 0; display: grid; gap: var(--space-4); }
      .insights .insights-history > li { padding: 0; border: 0; }
      .insights .insights-revision {
        padding: var(--space-5); background: var(--surface); border: 1px solid var(--rule); border-radius: .5rem;
      }
      .insights .insights-revision h3 { margin: var(--space-2) 0 var(--space-2); }
      .insights .insights-revision-facts { display: grid; gap: var(--space-3); margin: var(--space-4) 0 0; }
      .insights .insights-revision-facts dd { font-family: var(--font-body); white-space: pre-line; }
      .insights details { margin-top: var(--space-3); border: 1px solid var(--rule); border-radius: .35rem; background: var(--surface-2); }
      .insights summary { padding: var(--space-3); cursor: pointer; line-height: 1.5; font-family: var(--font-mono); font-size: var(--text-sm); }
      .insights blockquote {
        margin: 0; padding: var(--space-4); border-top: 1px solid var(--rule);
        white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.65; font-size: var(--text-sm);
      }
      .insights .insights-back { display: inline-flex; margin-bottom: var(--space-4); }
      @media (max-width: 640px) {
        .insights .insights-fields, .insights .insights-summary { grid-template-columns: minmax(0, 1fr); }
        .insights .insights-panel, .insights .insights-revision { padding: var(--space-4); }
        .insights .insights-toolbar { align-items: stretch; flex-direction: column; }
        .insights .insights-header { align-items: flex-start; flex-direction: column; }
      }
    </style>
    """
  end
end
