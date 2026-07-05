# How to plan and execute tasks in this project

## Zero Warnings & Zero Errors Policy

**All code changes must compile with zero warnings and zero errors.** This is a strict, non-negotiable requirement for all future development.

- Before marking any task as complete, run `mix compile` and verify zero warnings and zero errors
- If a change introduces a new warning (unused variable, unused function, ungrouped clauses, unused alias, etc.), fix it immediately as part of the same task
- If removing a function, verify its dependencies (aliases, helpers) are also cleaned up
- Never leave dead code behind — remove unused functions, aliases, and imports as you go
- This applies to all work: new features, bug fixes, refactors, and maintenance

## Very Important Point

This project is Ash Framework First, Phoenix Liveview second, DaisyUI third and Elixir fourth. Ensure and confirm this approach for all changes.

## Overview

This document provides practical guidance for planning and executing tasks using a workflow based on the the files in this worklog/ folder. If you already have your own instructions, follow them first then reflect your planning and execution process following this document to have process tracking and history.

## Example set of files

The following is an example set of files that you will find in the `worklog/` folder, as you can see there is a pattern for the files, first a date (the _current_ date when the iteration started), then an iteration number, then the type of the document, and finally a slug based on the name of the document.

```
250622-I001-prd-new_feature.md
250622-I001-tasks-new_feature.md
250622-I001-summary-new_feature.md
250630-I002-prd-some_other_feature.md
250630-I002-tasks-some_other_feature.md
250630-I002-summary-some_other_feature.md
```

## Core Workflow

This is the main core workflow you will follow to work together with the user in this project

1. The folder `worklog/` is the source of truth for the project, where prds, tasks, summaries, and other files are orgganized.
2. All the files in the `worklog/` folder are in markdown format.
3. You should also check:

- The `README.md` file on the root of the project for general context about the project.
- The `guides/` folder on the root of the project for more detailed patterns and examples of usage of the libraries used in this project for proper task planning and execution.

4. The names of the files in the `worklog/` folder should follow the pattern `YYMMDD-Innn-type-name_of_the_task.md`:
   1. `YYMMDD`: The date when the iteration was started in a abbreviated format YearMonthDay, defaults to the _current_ date.
   2. `INNN`: The iteration number (prefixed with `I` that stands for "Iteration"), which is a consecutive number starting from 001 incrementing by 1 for each new iteration, independent of the date.
   3. `type`: The type of the document, that can be one of the following: `prd`, `tasks`, `summary`, or other types as required by the user, for example `architecture`, `design`, `research`, etc.
   4. `name_of_the_iteration`: A slug for the iteration name, with the words separated by a underline.
5. Before starting with a new iteration, check if there is a summary for the previous iteration, and read it to quickly gather insights and context about the previous iteration.
6. Each iteration should start with a `prd` type document, e.g. `251121-I083-prd-iteration_foo_bar.md`, it should be a clear and concise _high level_ overview of the iteration with no bs, no fillers, no fluff, the following sections are suggested:

- PRD Title
- Problem Statement
- Objective
- Goals & Success Criteria
- What's out of the scope of this iteration
- Users & Personas
- Acceptance Criteria
- Technical Overview
  - Files/Modules of interested
  - Domains and Resources of Interest
  - Suggested step

7. Once the user approves the PRD create a matching `tasks` type documents, where you are going to create a hierarchical list of tasks to be done in order to implement the plan, use the following structure:

```markdown
# Tasks for the iteration

- [ ] Big Task 1
  - [ ] Subtask 1
  - [ ] Subtask 2
  - ...
- [ ] Big Task 2
  - [ ] Subtask 1
  - [ ] Subtask 2
  - ...
```

8. Everytime you complete a task, mark it as completed in the `tasks` type document.

- If you can't complete the task, it's OK, leave it as it is and add a comment to it.
- Do not move to the next task until the current one is completed and marked as completed or you explained why you could not complete it or why it is not relevant.

9. Always work in a branch based on the task name, for example: `251231-I201-foo_bar`

- The type is irrelevant for the branch name.
- If the branch already exists, use it, otherwise create it.

10. When you mark a Big Task as completed, you should perform a "checkpoint commit" to the branch.

- The checkpoint commit should include all the changes made to the branch up to that point.
- There is no need to push these commits.
- Commit messages should starte with the following format: `nn. Big Task Name`
  - `nn` should start in 01 for each iteration/branch and increment by 1 for each new commit.
  - The commit message should include the list of the tasks that were completed since the last checkpoint commit.

11. When the last task of the iteration is completed, create a matching `summary` type document name following the same pattern of the `tasks` previous documents

- In this document you should write a summary of what was accomplished in the iteration, this summary should be based on the up-to-date content of the `prd` document and the `tasks` docume

12. When the user explicitly instructs you to do so, you will follow this steps:
1. Check there are no pending changes to commit.
1. If not, commit all the pending changes to the branch.
1. Perform a squash merge to main so we can start a new iteration in a fresh branch.
1. Notify the user it is ready for the user to push the changes to the remote repository.

## Why it this workflow important?

This workflow is important because it provides a clear and structured way to plan and execute iterations that leaves a history of the plan work, the executed tasks and summaries, helping you and the user to keep track of the progress of the project and ease future iterations.

## Very Important Point

- This project is Ash Framework First, Phoenix Liveview second, DaisyUI third and Elixir fourth. Ensure and confirm this approach for all changes.
- When tasks are completed, highlight that development is complete and ready for my testing:
  - Refrain from declaring that tasks successfully completed and ready for deployment or production use
  - Refrain from declaring that system is fully functional or operational

## File Modification Approach

When removing/changing config files: 1) Edit source files directly, 2) Verify changes work, 3) Remove runtime sed/grep commands from scripts. Direct edits are more reliable than runtime modifications.

- My editor of choice is nvim
- every activity for this project is Ash first, Phoenix LiveView second, DaisyUI third and Elixir fourth. Refrain from adding javascript
- If a server is already running use that rather than spqwning a new one
- When adding functionality via the /pm:init-iteration, always ask who should have access to the functionality

## Tooltip Pattern for Nested Elements

When tooltips need to appear inside nested containers (modals, tables, etc.), use the `FloatingTooltip` JS hook pattern instead of relying on CSS z-index alone. CSS stacking contexts make it impossible for tooltips to appear above sibling elements when deeply nested.

**The pattern:**
1. Add `phx-hook="FloatingTooltip"` to the parent container
2. Use `dropdown-hover` with a `dayview-tip` class on tooltip content
3. The hook clones the tooltip to `document.body` with `position: fixed` on hover
4. This bypasses all stacking context issues and works on all browsers

**Location:** `assets/js/app.js` - `FloatingTooltip` hook

**Why not use DaisyUI's native tooltip or CSS-only solutions?**
- DaisyUI tooltips have the same stacking context limitations
- CSS `z-index` only works within the same stacking context
- The HTML `popover` API lacks Firefox/Safari support

## Confirmation Modal Pattern

All confirmation modals (delete, remove, warnings, prerequisites) must use the same consistent structure. **Never use browser `data-confirm` dialogs or basic DaisyUI `modal modal-open`.**

**Structure:**
```heex
<div class="fixed inset-0 z-[9999] flex items-center justify-center bg-black/50">
  <div class="bg-base-100 rounded-xl shadow-2xl max-w-sm mx-4 w-full overflow-hidden">
    <!-- Header: coloured tint + circular icon badge -->
    <div class="px-6 py-4 bg-{color}/10 border-b border-{color}/20 flex items-center gap-3">
      <div class="w-10 h-10 rounded-full bg-{color}/20 flex items-center justify-center flex-shrink-0">
        <svg class="h-5 w-5 text-{color}" ...><!-- context icon --></svg>
      </div>
      <div>
        <h3 class="text-lg font-bold text-base-content">Title</h3>
        <p class="text-sm text-base-content/60">Optional subtitle</p>  <!-- if needed -->
      </div>
    </div>
    <!-- Body -->
    <div class="px-6 py-5">
      <p class="text-sm text-base-content/80">Message text</p>
    </div>
    <!-- Footer -->
    <div class="px-6 py-4 bg-base-200/30 border-t border-base-200 flex gap-2 justify-end">
      <button class="btn btn-sm btn-ghost">Cancel</button>
      <button class="btn btn-sm btn-{color}">Action</button>
    </div>
  </div>
</div>
```

**Colour conventions:**
- `error` — destructive actions (delete, remove)
- `warning` — irreversible state changes (close job)
- `primary` — constructive actions (generate invoice)
- `success/error` header tint — prerequisite checklists (green if all pass, red if any fail)

**Icon conventions:**
- Trash icon for delete/remove
- Warning triangle for irreversible actions
- Checkmark/warning for prerequisite modals

**Examples in codebase:**
- `day_view_component.ex` — prerequisite modals, close job confirmation, delete job
- `show.ex` — remove worker/equipment/lifting equipment, delete docket

## Command Interpretation

- When asked to "create" or "write" something (like a commit message), ONLY output the text - do NOT execute commands
- When asked to "make a commit" or "commit the code", THEN execute the git commit
- Always confirm before executing destructive or irreversible actions
- "Create a commit message" ≠ "Create a commit"
