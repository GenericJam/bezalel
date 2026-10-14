defmodule Bezalel.Views.Sheets do
  @moduledoc "The bottom sheets: choose a model, confirm a delete, a Hebrew word."
  import Mob.Sigil

  alias Bezalel.{Models, Scripture}
  alias MobBezalel.UI

  @doc "The sheet for `assigns.sheet`, or nothing."
  def render(%{sheet: nil}), do: []

  def render(assigns) do
    style = UI.sheet_style()
    dismiss = {self(), :sheet}
    content = content(assigns.sheet, assigns)

    ~MOB"""
    <Sheet
      detents={[:medium, :large]}
      on_dismiss={dismiss}
      background={style.background}
      corner_radius={style.corner_radius}
      scrim={style.scrim}
      drag_indicator_color={style.drag_indicator_color}
      drag_indicator_width={style.drag_indicator_width}
      drag_indicator_height={style.drag_indicator_height}
      drag_indicator_rail_height={style.drag_indicator_rail_height}
    >
      <Scroll>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={24}
          padding_bottom={34}
          gap={14}
          fill_width={true}
        >
          {content}
        </Column>
      </Scroll>
    </Sheet>
    """
  end

  defp content(:models, assigns) do
    groups =
      for {group, models} <- Models.groups() do
        rows = Enum.map(models, &model_row(&1, assigns.model_id))

        ~MOB"""
        <Column gap={6} fill_width={true}>
          {UI.kicker(group)}
          {rows}
        </Column>
        """
      end

    [
      ~MOB"""
      <Row align={:end} fill_width={true}>
        <Text
          text="Choose a model"
          font={:display}
          text_size={24}
          text_color={:on_background}
          weight={1}
        />
        <Text text="Switch anytime; the chat stays" text_size={12} text_color={:muted} />
      </Row>
      """
      | groups
    ]
  end

  defp content({:confirm_delete, id}, _assigns) do
    confirm = {self(), {:study, {:confirm_delete, id}}}
    keep = {self(), :sheet}

    [
      ~MOB(<Text text="Delete this message?" font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text
  text="Replies further down were built on it. Removing it can leave the agent working from a conversation that no longer quite adds up. The messages below it stay."
  text_size={14.5}
  line_height={1.55}
  text_color={:on_background}
/>),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Delete anyway", confirm, :danger, weight: 1, height: 48)}
        {UI.pill_button("Keep it", keep, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  defp content({:word, key}, assigns) do
    w = Scripture.word(key)
    {before, after_} = w.phrase
    model = Models.get(assigns.model_id)
    ask = {self(), {:study, {:ask_word, key}}}
    meta = "#{w.strong} · #{w.count}× in the OT"
    refs = for r <- w.refs, do: UI.chip(r)

    [
      ~MOB(<Text
  text={before <> w.heb <> after_}
  font={:hebrew}
  text_size={21}
  line_height={1.8}
  text_color={:muted}
  text_align="right"
  fill_width={true}
/>),
      ~MOB"""
      <Row gap={12} align={:center} fill_width={true}>
        <Text text={w.heb} font={:hebrew_medium} text_size={40} text_color={:on_background} />
        <Column gap={2}>
          <Text text={w.translit} font={:scripture_italic} text_size={19} text_color={:on_background} />
          <Text text={meta} text_size={12} text_color={:muted} />
        </Column>
      </Row>
      """,
      ~MOB(<Text
  text={w.gloss}
  font={:scripture}
  text_size={19}
  line_height={1.45}
  text_color={:on_background}
/>),
      ~MOB(<Text text={w.note} text_size={14.5} line_height={1.55} text_color={:on_background} />),
      UI.kicker("Cross-references"),
      ~MOB(<Wrap spacing={8} run_spacing={8} fill_width={true}>
  {refs}
</Wrap>),
      UI.pill_button("Ask #{model.name} about #{w.translit}", ask)
    ]
  end

  defp model_row(model, current) do
    border = if model.id == current, do: :secondary, else: :border
    tap = {self(), {:model, model.id}}
    tags = for t <- model.tags, do: tag(t)

    ~MOB"""
    <Box
      background={:surface}
      border_color={border}
      border_width={1.5}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={8}
      padding_bottom={8}
      fill_width={true}
      on_tap={tap}
    >
      <Row gap={12} align={:center} fill_width={true}>
        <Box width={10} height={10} corner_radius={5} background={model.dot} fill_width={false} />
        <Column gap={2} weight={1}>
          <Text text={model.name} font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Text text={model.note} text_size={12} text_color={:muted} />
        </Column>
        {tags}
      </Row>
    </Box>
    """
  end

  defp tag(label) do
    ~MOB"""
    <Box
      border_color={:border}
      border_width={1}
      corner_radius={10}
      padding_left={8}
      padding_right={8}
      padding_top={3}
      padding_bottom={3}
      fill_width={false}
    >
      <Text
        text={label}
        font={:ui_semibold}
        text_size={10}
        letter_spacing={0.6}
        text_color={:muted}
      />
    </Box>
    """
  end
end
