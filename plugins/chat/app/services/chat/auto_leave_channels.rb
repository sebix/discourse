# frozen_string_literal: true

module Chat
  class AutoLeaveChannels
    include Service::Base

    ALLOWED_GROUP_PERMISSIONS = [
      CategoryGroup.permission_types[:create_post],
      CategoryGroup.permission_types[:full],
    ]

    policy :chat_enabled?

    contract do
      attribute :event
      attribute :user_id, :integer
      attribute :group_id, :integer
      attribute :channel_id, :integer
      attribute :category_id, :integer
    end

    step :remove_memberships

    private

    def chat_enabled?
      SiteSetting.chat_enabled
    end

    def remove_memberships
      group_ids = SiteSetting.chat_allowed_groups_map
      group_permissions = ALLOWED_GROUP_PERMISSIONS

      if !group_ids.include?(Group::AUTO_GROUPS[:everyone])
        sql = <<~SQL
          DELETE FROM user_chat_channel_memberships uccm
          WHERE NOT EXISTS (
            SELECT 1 
            FROM group_users gu 
            WHERE gu.user_id = uccm.user_id 
            AND gu.group_id IN (:group_ids)
          )
          RETURNING chat_channel_id, user_id
        SQL

        users_removed_map = Hash.new { |h, k| h[k] = [] }

        DB
          .query_array(sql, group_ids:)
          .each { |channel_id, user_id| users_removed_map[channel_id] << user_id }

        Chat::Action::PublishAutoRemovedUser.call(event: context.event, users_removed_map:)
      end

      user_sql = context.user_id.to_i > 0 ? "AND u.id = #{context.user_id}" : ""
      channel_sql = context.channel_id.to_i > 0 ? "AND cc.id = #{context.channel_id}" : ""
      category_sql = context.category_id.to_i > 0 ? "AND c.id = #{context.category_id}" : ""

      sql = <<~SQL
        WITH valid_permissions AS (
          SELECT gu.user_id, cg.category_id
          FROM group_users gu
          JOIN category_groups cg ON cg.group_id = gu.group_id AND cg.permission_type IN (:group_permissions)
        )
        DELETE FROM user_chat_channel_memberships
        WHERE (user_id, chat_channel_id) IN (
          SELECT uccm.user_id, uccm.chat_channel_id
          FROM user_chat_channel_memberships uccm
          JOIN users u ON u.id = uccm.user_id AND u.id > 0 AND u.moderator = FALSE AND u.admin = FALSE #{user_sql}
          JOIN chat_channels cc ON cc.id = uccm.chat_channel_id AND cc.chatable_type = 'Category' #{channel_sql}
          JOIN categories c ON c.id = cc.chatable_id AND c.read_restricted = TRUE #{category_sql}
          LEFT JOIN valid_permissions vp ON vp.user_id = uccm.user_id AND vp.category_id = c.id
          WHERE vp.user_id IS NULL
        )
        RETURNING chat_channel_id, user_id
      SQL

      users_removed_map = Hash.new { |h, k| h[k] = [] }

      DB
        .query_array(sql, group_permissions:)
        .each { |channel_id, user_id| users_removed_map[channel_id] << user_id }

      Chat::Action::PublishAutoRemovedUser.call(event: context.event, users_removed_map:)
    end
  end
end
