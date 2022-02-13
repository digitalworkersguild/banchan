defmodule Banchan.Repo.Migrations.CreateStudios do
  use Ecto.Migration

  def change do
    create table(:studios) do
      add :name, :string, null: false
      add :summary, :text
      add :handle, :citext, null: false
      add :description, :text
      add :header_img, :string
      add :card_img, :string
      add :default_terms, :text
      add :stripe_id, :string
      add :stripe_charges_enabled, :boolean, default: false
      add :stripe_details_submitted, :boolean, default: false
      add :platform_fee, :decimal, null: false
      timestamps()
    end

    create table(:users_studios, primary_key: false) do
      add :user_id, references(:users), null: false
      add :studio_id, references(:studios), null: false
    end
  end
end
