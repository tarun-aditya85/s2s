import { PubSub } from '@google-cloud/pubsub';
import { Kinesis } from 'aws-sdk';
import { ClickEvent, PostbackEvent, ErrorEvent } from '../types';

type CloudProvider = 'gcp' | 'aws';

export class EventStreamService {
  private provider: CloudProvider;
  private gcpPubSub?: PubSub;
  private awsKinesis?: Kinesis;

  constructor() {
    this.provider = (process.env.CLOUD_PROVIDER as CloudProvider) || 'gcp';

    if (this.provider === 'gcp') {
      this.initGCP();
    } else {
      this.initAWS();
    }
  }

  private initGCP(): void {
    this.gcpPubSub = new PubSub({
      projectId: process.env.GCP_PROJECT_ID,
    });
    console.log('GCP Pub/Sub initialized');
  }

  private initAWS(): void {
    this.awsKinesis = new Kinesis({
      region: process.env.AWS_REGION || 'us-east-1',
    });
    console.log('AWS Kinesis initialized');
  }

  /**
   * Publish click event to stream
   * GCP: Pub/Sub -> Dataflow -> GCS (Parquet)
   * AWS: Kinesis Firehose -> S3 (Parquet auto-conversion)
   */
  async publishClickEvent(event: ClickEvent): Promise<void> {
    try {
      if (this.provider === 'gcp') {
        await this.publishToGCP(
          process.env.GCP_PUBSUB_TOPIC_CLICKS || 's2s-clicks',
          event
        );
      } else {
        await this.publishToAWS(
          process.env.AWS_KINESIS_STREAM_CLICKS || 's2s-clicks',
          event
        );
      }
    } catch (error) {
      console.error('Failed to publish click event:', error);
      throw error;
    }
  }

  /**
   * Publish postback event to stream
   */
  async publishPostbackEvent(event: PostbackEvent): Promise<void> {
    try {
      if (this.provider === 'gcp') {
        await this.publishToGCP(
          process.env.GCP_PUBSUB_TOPIC_POSTBACKS || 's2s-postbacks',
          event
        );
      } else {
        await this.publishToAWS(
          process.env.AWS_KINESIS_STREAM_POSTBACKS || 's2s-postbacks',
          event
        );
      }
    } catch (error) {
      console.error('Failed to publish postback event:', error);
      throw error;
    }
  }

  /**
   * Publish error event to stream
   */
  async publishErrorEvent(event: ErrorEvent): Promise<void> {
    try {
      if (this.provider === 'gcp') {
        await this.publishToGCP(
          process.env.GCP_PUBSUB_TOPIC_ERRORS || 's2s-errors',
          event
        );
      } else {
        await this.publishToAWS(
          process.env.AWS_KINESIS_STREAM_ERRORS || 's2s-errors',
          event
        );
      }
    } catch (error) {
      console.error('Failed to publish error event:', error);
      // Don't throw - we don't want error logging to break the main flow
    }
  }

  /**
   * GCP Pub/Sub publishing
   */
  private async publishToGCP(topicName: string, data: any): Promise<void> {
    if (!this.gcpPubSub) {
      throw new Error('GCP Pub/Sub not initialized');
    }

    const topic = this.gcpPubSub.topic(topicName);
    const dataBuffer = Buffer.from(JSON.stringify(data));

    // Add tenant_id as attribute for routing/filtering
    const attributes = {
      tenant_id: data.tenant_id,
      event_type: this.getEventType(data),
    };

    await topic.publishMessage({
      data: dataBuffer,
      attributes,
    });
  }

  /**
   * AWS Kinesis publishing
   */
  private async publishToAWS(streamName: string, data: any): Promise<void> {
    if (!this.awsKinesis) {
      throw new Error('AWS Kinesis not initialized');
    }

    const params = {
      StreamName: streamName,
      Data: JSON.stringify(data),
      PartitionKey: data.tenant_id, // Partition by tenant for balanced sharding
    };

    await this.awsKinesis.putRecord(params).promise();
  }

  /**
   * Determine event type from data structure
   */
  private getEventType(data: any): string {
    if ('click_id' in data && 'target_url' in data) return 'click';
    if ('conversion_value' in data) return 'postback';
    if ('error_type' in data) return 'error';
    return 'unknown';
  }

  /**
   * Health check for cloud services
   */
  async healthCheck(): Promise<{ connected: boolean; provider: string }> {
    try {
      if (this.provider === 'gcp') {
        // Simple check - verify client is initialized
        return {
          connected: !!this.gcpPubSub,
          provider: 'gcp',
        };
      } else {
        // For AWS, we could do a listStreams call, but that's expensive
        // Just verify client is initialized
        return {
          connected: !!this.awsKinesis,
          provider: 'aws',
        };
      }
    } catch (error) {
      return {
        connected: false,
        provider: this.provider,
      };
    }
  }
}

export default new EventStreamService();
