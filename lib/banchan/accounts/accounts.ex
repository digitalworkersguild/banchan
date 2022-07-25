defmodule Banchan.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Ueberauth.Auth

  alias Banchan.Accounts.{DisableHistory, Notifications, User, UserFilter, UserToken}
  alias Banchan.Repo
  alias Banchan.Uploads
  alias Banchan.Workers.{EnableUser, Thumbnailer}

  alias BanchanWeb.UserAuth

  @pubsub Banchan.PubSub
  @rand_pass_length 32

  ## Fetching data

  @doc """
  General paginated User-listing query.

  ## Options

    * `:page_size` - The number of users to return per page.
    * `:page` - The page number to return.

  """
  def list_users(%User{} = actor, %UserFilter{} = filter, opts \\ []) do
    from(u in User,
      as: :user,
      join: a in User,
      as: :actor,
      on: a.id == ^actor.id,
      where: :admin in a.roles or :mod in a.roles,
      order_by: [desc: u.inserted_at]
    )
    |> filter_query(filter)
    |> Repo.paginate(
      page_size: Keyword.get(opts, :page_size, 24),
      page: Keyword.get(opts, :page, 1)
    )
  end

  defp filter_query(q, filter) do
    if filter.query && filter.query != "" do
      q
      |> where(
        [user: u],
        fragment("websearch_to_tsquery(?) @@ (?).search_vector", ^filter.query, u)
      )
    else
      q
    end
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples
      iex> get_user!(123)
      %User{}
      iex> get_user!(456)
      ** (Ecto.NoResultsError)
  """
  def get_user!(id), do: Repo.get!(User, id) |> Repo.preload(:disable_info)

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        where: u.email == ^email,
        preload: [:pfp_img, :pfp_thumb, :header_img, :disable_info]
    )
  end

  @doc """
  Gets a user by handle.

  ## Examples

      iex> get_user_by_email("foo")
      %User{}

      iex> get_user_by_email("unknown")
      nil

  """
  def get_user_by_handle!(handle) when is_binary(handle) do
    Repo.one!(
      from u in User,
        where: u.handle == ^handle,
        preload: [:pfp_img, :pfp_thumb, :header_img, :disable_info]
    )
  end

  @doc """
  Gets a user by identifier (email or handle) and password.

  ## Examples

      iex> get_user_by_identifier_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_identifier_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_identifier_and_password(ident, password)
      when is_binary(ident) and is_binary(password) do
    user =
      Repo.one(
        from u in User,
          where: u.email == ^ident or u.handle == ^ident,
          preload: [:pfp_img, :pfp_thumb, :header_img, :disable_info]
      )

    if User.valid_password?(user, password), do: user
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The same as above, but used for testing purposes only!

  This is used so that MFA settings and confirmed_at can be set instantly.
  """
  def register_user_test(attrs) do
    %User{}
    |> User.registration_test_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Register an admin.
  """
  def register_admin(attrs) do
    %User{}
    |> User.admin_registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Either find or create a user based on Ueberauth OAuth credentials.
  """
  def find_or_create_user(%Auth{provider: :twitter} = auth) do
    {:ok, ret} =
      Repo.transaction(fn ->
        case Repo.one(from u in User, where: u.twitter_uid == ^auth.uid) do
          %User{} = user ->
            {:ok, user}

          nil ->
            create_user_from_twitter(auth)
            |> add_oauth_pfp(auth)
        end
      end)

    ret
  end

  def find_or_create_user(%Auth{provider: :discord} = auth) do
    {:ok, ret} =
      Repo.transaction(fn ->
        case Repo.one(from u in User, where: u.discord_uid == ^auth.uid) do
          %User{} = user ->
            {:ok, user}

          nil ->
            create_user_from_discord(auth)
            |> add_oauth_pfp(auth)
        end
      end)

    ret
  end

  def find_or_create_user(%Auth{provider: :google} = auth) do
    {:ok, ret} =
      Repo.transaction(fn ->
        case Repo.one(from u in User, where: u.google_uid == ^auth.uid) do
          %User{} = user ->
            {:ok, user}

          nil ->
            create_user_from_google(auth)
            |> add_oauth_pfp(auth)
        end
      end)

    ret
  end

  def find_or_create_user(%Auth{}) do
    {:error, :unsupported}
  end

  defp create_user_from_twitter(%Auth{} = auth) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    pw = random_password()

    attrs = %{
      twitter_uid: auth.uid,
      email: auth.info.email,
      handle: auth.info.nickname,
      name: auth.info.name,
      bio: auth.info.description,
      twitter_handle: auth.info.nickname,
      password: pw,
      password_confirmation: pw,
      confirmed_at: now
    }

    case %User{}
         |> User.registration_oauth_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Enum.any?(changeset.errors, fn {field, _} -> field == :handle end) do
          %User{}
          |> User.registration_oauth_changeset(%{
            attrs
            | handle: "user#{:rand.uniform(100_000_000)}"
          })
          |> Repo.insert()
        else
          {:error, changeset}
        end
    end
  end

  defp create_user_from_discord(%Auth{} = auth) do
    pw = random_password()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = %{
      discord_uid: auth.uid,
      email: auth.info.email,
      handle:
        auth.extra.raw_info.user["username"] <> "_" <> auth.extra.raw_info.user["discriminator"],
      name:
        auth.extra.raw_info.user["username"] <> "#" <> auth.extra.raw_info.user["discriminator"],
      discord_handle:
        auth.extra.raw_info.user["username"] <> "#" <> auth.extra.raw_info.user["discriminator"],
      password: pw,
      password_confirmation: pw,
      confirmed_at: now
    }

    case %User{}
         |> User.registration_oauth_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Enum.any?(changeset.errors, fn {field, _} -> field == :handle end) do
          %User{}
          |> User.registration_oauth_changeset(%{
            attrs
            | handle: "user#{:rand.uniform(100_000_000)}"
          })
          |> Repo.insert()
        else
          {:error, changeset}
        end
    end
  end

  defp create_user_from_google(%Auth{} = auth) do
    pw = random_password()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = %{
      google_uid: auth.uid,
      email: auth.info.email,
      handle: "user#{:rand.uniform(100_000_000)}",
      password: pw,
      password_confirmation: pw,
      confirmed_at: now
    }

    case %User{}
         |> User.registration_oauth_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Enum.any?(changeset.errors, fn {field, _} -> field == :email end) do
          %User{}
          |> User.registration_oauth_changeset(%{
            attrs
            | email: nil
          })
          |> Repo.insert()
        else
          {:error, changeset}
        end
    end
  end

  defp add_oauth_pfp({:ok, %User{} = user}, %Auth{info: %{image: nil}}) do
    {:ok, user}
  end

  defp add_oauth_pfp({:ok, %User{} = user}, %Auth{info: %{image: url}}) when is_binary(url) do
    tmp_file =
      Path.join([
        System.tmp_dir!(),
        "oauth-pfp-#{:rand.uniform(100_000_000)}" <> Path.extname(url)
      ])

    resp = HTTPoison.get!(url)
    File.write!(tmp_file, resp.body)
    %{format: format} = Mogrify.identify(tmp_file)

    {pfp, thumb} =
      make_pfp_images!(user, user, tmp_file, "image/#{format}", Path.basename(tmp_file))

    File.rm!(tmp_file)

    update_user_profile(user, user, %{
      "pfp_img_id" => pfp.id,
      "pfp_thumb_id" => thumb.id
    })
  end

  defp add_oauth_pfp({:error, error}, _) do
    {:error, error}
  end

  defp random_password do
    :crypto.strong_rand_bytes(@rand_pass_length) |> Base.encode64()
  end

  ## Admin

  @doc """
  Disables a user.
  """
  def disable_user(%User{} = actor, %User{} = user, attrs) do
    if :admin in actor.roles ||
         (:mod in actor.roles && :admin not in user.roles) do
      {:ok, ret} =
        Repo.transaction(fn ->
          dummy = %DisableHistory{} |> DisableHistory.disable_changeset(attrs)

          with {:ok, job} <-
                 (case Ecto.Changeset.fetch_change(dummy, :disabled_until) do
                    {:ok, until} when not is_nil(until) ->
                      EnableUser.schedule_unban(user, until)

                    _ ->
                      {:ok, nil}
                  end) do
            %DisableHistory{
              user_id: user.id,
              disabled_by_id: actor.id,
              disabled_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
              lifting_job_id: job && job.id
            }
            |> DisableHistory.disable_changeset(attrs)
            |> Repo.insert()
          end
        end)

      ret
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Re-enable a previously disabled user.
  """
  def enable_user(actor, %User{} = user, reason, cancel \\ true) do
    if is_nil(actor) ||
         :admin in actor.roles ||
         (:mod in actor.roles && :admin not in user.roles) do
      changeset = DisableHistory.enable_changeset(%DisableHistory{}, %{lifted_reason: reason})

      if changeset.valid? do
        {:ok, ret} =
          Repo.transaction(fn ->
            {_, [history | _]} =
              Repo.update_all(
                from(h in DisableHistory,
                  where: h.user_id == ^user.id and is_nil(h.lifted_at),
                  select: h
                ),
                set: [
                  lifted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
                  lifted_by_id: actor && actor.id,
                  lifted_reason: reason
                ]
              )

            if cancel do
              EnableUser.cancel_unban(history)
            end

            {:ok, history}
          end)

        ret
      else
        {:error, changeset}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Utility for determining whether an actor can modify a target user. Used for
  allowing admins to modify user-only stuff.
  """
  def can_modify_user?(%User{} = actor, %User{} = target) do
    actor.id == target.id ||
      :admin in actor.roles ||
      (:mod in actor.roles && :admin not in target.roles)
  end

  ## Settings and Profile

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user handle.

  ## Examples

      iex> change_user_handle(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_handle(user, attrs \\ %{}) do
    User.handle_changeset(user, attrs)
  end

  @doc """
  Updates admin-level fields for a user, such as their roles.
  """
  def update_admin_fields(%User{} = actor, %User{} = user, attrs \\ %{}) do
    User.admin_changeset(actor, user, attrs)
    |> Repo.update()
  end

  @doc """
  Updates the user profile fields.

  ## Examples

      iex> update_user_profile(actor, user, %{handle: ..., bio: ..., ...})
      {:ok, %User{}}

  """
  def update_user_profile(%User{} = actor, %User{} = user, attrs) do
    if can_modify_user?(actor, user) do
      user
      |> User.profile_changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Saves a profile picture and schedules generation of corresponding thumbnails.
  """
  def make_pfp_images!(%User{} = actor, %User{} = user, src, type, name) do
    if can_modify_user?(actor, user) do
      upload = Uploads.save_file!(user, src, type, name)

      {:ok, pfp} =
        Thumbnailer.thumbnail(
          upload,
          dimensions: "512x512",
          name: "profile.jpg"
        )

      {:ok, thumb} =
        Thumbnailer.thumbnail(
          upload,
          dimensions: "128x128",
          name: "thumbnail.jpg"
        )

      {pfp, thumb}
    else
      raise "Unauthorized"
    end
  end

  @doc """
  Saves a header image and schedules generation of processed version for site display.
  """
  def make_header_image!(%User{} = actor, %User{} = user, src, type, name) do
    if can_modify_user?(actor, user) do
      upload = Uploads.save_file!(user, src, type, name)

      {:ok, header} =
        Thumbnailer.thumbnail(
          upload,
          dimensions: "1200",
          name: "header.jpg"
        )

      header
    else
      raise "Unauthorized"
    end
  end

  @doc """
  Updates the user handle.

  ## Examples

      iex> update_user_handle(user, "valid password", %{handle: ...})
      {:ok, %User{}}

      iex> update_user_handle(user, "invalid password", %{handle: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_handle(user, password, attrs) do
    changeset =
      user
      |> User.handle_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Emulates that the email will change without actually changing it in the
  database. Used exclusively for OAuth accounts that didn't have an email to
  begin with, so password is not checked.

  ## Examples

      iex> apply_new_user_email(user, %{email: ...})
      {:ok, %User{}}
  """
  def apply_new_user_email(user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context) do
    changeset = user |> User.email_changeset(%{email: email}) |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  @doc """
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_update_email_instructions(user, current_email, &Routes.user_update_email_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    Notifications.update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Generates a new TOTP secret for a user.

  ## Examples

      iex> generate_totp_secret(user)
      {:ok, %User{}}

      iex> generate_totp_secret(user)
      {:error, %Ecto.Changeset{}}

  """
  def generate_totp_secret(user) do
    secret = NimbleTOTP.secret()

    changeset =
      user
      |> User.totp_secret_changeset(%{totp_secret: secret})

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Deactivates a user's TOTP secret.

  ## Examples

      iex> deactivate_totp(user)
      {:ok, %User{}}

      iex> deactivate_totp(user)
      {:error, %Ecto.Changeset{}}

  """
  def deactivate_totp(user) do
    changeset =
      user
      |> User.totp_secret_changeset(%{totp_secret: nil, totp_activated: false})

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Activates a TOTP secret for a user.

  ## Examples

      iex> activate_totp(user, token)
      {:ok, %User{}}

      iex> activate_totp(user, token)
      {:invalid_token, %Ecto.Changeset{}}

  """
  def activate_totp(user, token) do
    changeset =
      user
      |> User.totp_secret_changeset(%{totp_activated: true})

    if NimbleTOTP.valid?(user.totp_secret, token) do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, changeset)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, :user, changeset, _} -> {:error, changeset}
      end
    else
      {:invalid_token, changeset}
    end
  end

  @doc """
  Updates the user's preferences for mature content filtering.
  """
  def update_maturity(user, attrs) do
    user
    |> User.maturity_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the user's preferences for muted words.
  """
  def update_muted(user, attrs) do
    user
    |> User.muted_changeset(attrs)
    |> Repo.update()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query) |> Repo.preload(:disable_info)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Logs out a user from everything.
  """
  def logout_user(%User{} = user) do
    # Delete all user tokens
    Repo.delete_all(UserToken.user_and_contexts_query(user, :all))

    # Broadcast to all LiveViews to immediately disconnect the user
    Phoenix.PubSub.broadcast_from(
      @pubsub,
      self(),
      UserAuth.pubsub_topic(),
      %Phoenix.Socket.Broadcast{
        topic: UserAuth.pubsub_topic(),
        event: "logout_user",
        payload: %{
          user: user
        }
      }
    )
  end

  @doc """
  Subscribes the current process to auth-related events (such as `logout_user`).
  """
  def subscribe_to_auth_events do
    Phoenix.PubSub.subscribe(@pubsub, UserAuth.pubsub_topic())
  end

  ## Confirmation

  @doc """
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &Routes.user_confirmation_url(conn, :confirm, &1))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &Routes.user_confirmation_url(conn, :confirm, &1))
      {:error, :already_confirmed}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      Notifications.confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc """
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &Routes.user_reset_password_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    Notifications.reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user |> Repo.preload(:disable_info)
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end
end
